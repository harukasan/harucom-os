# research: mruby-task プリエンプションと再入 mrb_vm_exec の callinfo 破壊

## ステータス

- **未適用** (2026-07-07 時点)。別タスクとして対応する。修正パッチは本ファイル末尾に保存。
- johakyu の作業では、自作コード側の VM 再入を減らす対処 (Pattern#rev の sort を純 Ruby 化、
  コミット 17c38e4) のみ適用済み。

## 症状

fixture_check の Sweep モード操作中に散発するハードフォルト (数時間の稼働で 2 回)。
fixture_check 固有ではなく、タイミング依存で任意のコードが踏み得る。

## デバッガ実測 (Debug Probe + openocd + VS Code Cortex-Debug)

- PreciseBusFault、`CFSR = 0x00008200` (PRECISERR + BFARVALID)、`HFSR = 0x40000000` (FORCED)
- `BFAR = 0x00103604` = フォルト時の `r3` = **破壊された `ci->pc`**
- フォルト命令は OP_RETURN 処理の `cipop` 直後、`ci->pc` からの次オペコードフェッチ
  (`ldrb r5, [r3, #0]`)
- コールスタックに `mrb_vm_exec` が 2 段 (C 関数経由で VM が再入した状態)

```
isr_hardfault (crt0.S:333)
<signal handler called>
mrb_vm_exec          <- フォルト (OP_RETURN の次命令フェッチ)
mrb_vm_exec          <- 再入元
execute_task
mrb_task_run
run_mruby (main.c)
```

## 根本原因

mruby-task (picoruby 拡張) のプリエンプション。vm.c の `RETURN_IF_TASK_STOPPED` は
全オペコード境界 (NEXT) で展開され、タイムスライス満了で `mrb->task.switching` が立つと
**再入の深さに関係なく `mrb_vm_exec` から即 return する**。

mruby 本体は VM 再入を一級市民として設計している (`mrb_funcall`/`mrb_yield` は公式 C API、
`CINFO_SKIP`/`CINFO_DIRECT`、OP_RETURN の C 境界 return、`MRB_THROW(prev_jmp)` の
ネスト跨ぎ例外伝播)。core の C 実装も多用する (ブロック付き `Array#sort` は C ヒープソートが
比較毎に yield、文字列補間は Ruby 定義 `to_s` を `mrb_funcall`、require / Sandbox eval も
再入)。

C→Ruby コールバック実行中 (`cipush(CINFO_SKIP)` → `mrb_vm_run` → 再入 exec) に
プリエンプトが発火すると:

1. 内側 exec が積んだ callinfo を pop しないまま C 呼び出し元へ nil を返す
2. C 呼び出し元は気付かず続行し、ci スタックと C スタックが食い違う
3. `execute_task` の resume は「現在の ci から 1 本の exec を再入」する設計なので、
   消えた C フレームは復元不能
4. 後続の OP_RETURN / cipop で壊れた `ci->pc` を踏んで BusFault

協調切替 (`Task.pass` / sleep) には `ci->cci > 0` ガードが既にある (task.c) が、
プリエンプト側に相当するガードが無い。wasm 移植でも同型バグを修正した前例がある
(preempt C-boundary crash、guard on cci>0)。

## 修正パッチ (検証済み・未適用)

方針: exec のネスト深さ `vm_nest` を導入し、switching による早期 return を
**タスク最外周の exec (`vm_nest <= 1`) に限定**する。ネスト中の切替はネスト境界まで
遅延する (正しさ優先、遅延は C コールバック 1 回分まで)。exec から longjmp で抜ける
3 箇所の `MRB_THROW(prev_jmp)` はラッパの decrement を飛ばすため、直前に明示 decrement
(忘れるとカウンタが漏れてプリエンプション恒久停止)。

対象: `lib/picoruby/mrbgems/picoruby-mruby/lib/mruby` (ネストした submodule、
origin = mruby/mruby、base commit 7a4622678ddc480dadcb3149ec29de1e9dded84d)。

一度ビルドして逆アセンブルで確認済み (switching 判定 106 箇所に vm_nest 比較が入る)。
ストレス再現手順: IRB で
`loop { 1.instance_eval { i = 0; while i < 100000; i += 1; end } }`
(ほぼ常時ネスト exec 中にタイムスライスが切れる)。未修正ファームでは遠からず
ハードフォルト、修正済みなら走り続けて Ctrl-C で復帰する。

```diff
diff --git a/include/mruby.h b/include/mruby.h
index b5a66dc18..3364f4e08 100644
--- a/include/mruby.h
+++ b/include/mruby.h
@@ -257,6 +257,7 @@ typedef struct mrb_task_state {
   volatile mrb_bool switching;      /* Context switch pending flag */
   struct mrb_task *main_task;       /* Main task wrapper for root context */
   uint8_t scheduler_lock;           /* Lock counter for synchronous execution */
+  uint8_t vm_nest;                  /* mrb_vm_exec nesting depth (preemption guard) */
 } mrb_task_state;
 #endif
 
diff --git a/src/vm.c b/src/vm.c
index ff2d63c7f..04d9be7d2 100644
--- a/src/vm.c
+++ b/src/vm.c
@@ -1535,16 +1535,28 @@ prepare_tagged_break(mrb_state *mrb, uint32_t tag, const mrb_callinfo *return_ci
 #define CALL_CODE_HOOKS() do { insn = BYTECODE_DECODER(*ci->pc); CODE_FETCH_HOOK(mrb, irep, ci->pc, regs); } while (0)
 
 #ifdef MRB_USE_TASK_SCHEDULER
+/* Preemptive switching may only return from the task's outermost
+ * mrb_vm_exec (vm_nest == 1). A nested exec, entered through a C
+ * function such as mrb_funcall or mrb_yield, must keep running:
+ * returning early would leave the callinfo frames it pushed while the
+ * C caller continues, and execute_task cannot restore the lost C
+ * frames when the task resumes. vm_nest is maintained by the
+ * mrb_vm_exec wrapper; the MRB_THROW(prev_jmp) exits decrement it
+ * explicitly because they bypass the wrapper's return path. */
 #define RETURN_IF_TASK_STOPPED(mrb) do { \
-  if ((mrb)->task.switching || (mrb)->c->status == MRB_TASK_STOPPED) \
+  if (((mrb)->task.switching && (mrb)->task.vm_nest <= 1) || (mrb)->c->status == MRB_TASK_STOPPED) \
     return mrb_nil_value(); \
 } while (0)
+#define TASK_VM_ENTER(mrb) ((mrb)->task.vm_nest++)
+#define TASK_VM_LEAVE(mrb) ((mrb)->task.vm_nest--)
 #define TASK_STOP(mrb) do { \
   if (mrb->c->status != MRB_TASK_STOPPED) \
     mrb->c->status = MRB_TASK_STOPPED; \
 } while (0)
 #else
 #define RETURN_IF_TASK_STOPPED(mrb)
+#define TASK_VM_ENTER(mrb)
+#define TASK_VM_LEAVE(mrb)
 #define TASK_STOP(mrb)
 #endif
 
@@ -1658,8 +1670,19 @@ hash_new_from_regs(mrb_state *mrb, mrb_int argc, mrb_int idx)
  *       when not using switch-based dispatch. It also manages the callinfo
  *       stack (`ci`) for tracking method/block calls.
  */
+static mrb_value mrb_vm_exec_body(mrb_state *mrb, const struct RProc *begin_proc, const mrb_code *iseq);
+
 MRB_API mrb_value
 mrb_vm_exec(mrb_state *mrb, const struct RProc *begin_proc, const mrb_code *iseq)
+{
+  TASK_VM_ENTER(mrb);
+  mrb_value ret = mrb_vm_exec_body(mrb, begin_proc, iseq);
+  TASK_VM_LEAVE(mrb);
+  return ret;
+}
+
+static mrb_value
+mrb_vm_exec_body(mrb_state *mrb, const struct RProc *begin_proc, const mrb_code *iseq)
 {
   /* mrb_assert(MRB_PROC_CFUNC_P(begin_proc)) */
   const mrb_irep *irep = begin_proc->body.irep;
@@ -2137,6 +2160,7 @@ RETRY_TRY_BLOCK:
             if (ci[1].cci == CINFO_SKIP) {
               mrb_assert(prev_jmp != NULL);
               mrb->jmp = prev_jmp;
+              TASK_VM_LEAVE(mrb);
               MRB_THROW(prev_jmp);
             }
           }
@@ -2152,6 +2176,7 @@ RETRY_TRY_BLOCK:
             if (!c->vmexec) goto L_RAISE;
             mrb->jmp = prev_jmp;
             if (!prev_jmp) return mrb_obj_value(mrb->exc);
+            TASK_VM_LEAVE(mrb);
             MRB_THROW(prev_jmp);
           }
         }
@@ -2691,6 +2716,7 @@ RETRY_TRY_BLOCK:
             mrb_gc_arena_restore(mrb, ai);
             mrb->c->vmexec = FALSE;
             mrb->jmp = prev_jmp;
+            TASK_VM_LEAVE(mrb);
             MRB_THROW(prev_jmp);
           }
         }
```

## ビルドの注意 (再適用時)

- vendored mruby の C 変更後は **プロジェクトルートで** `bundle exec rake distclean` →
  `bundle exec rake`。lib/picoruby 内で rake を打つと picoruby 自身の rake (host のみ) が
  走り、cross ビルドが古いまま残る。逆アセンブルで実バイナリを確認するのが確実
  (`arm-none-eabi-nm build/harucom_os.elf | grep mrb_vm_exec_body` が出れば適用済み)。
- picoruby-mrubyc の `_autogen_*.h` (git 管理外の生成物) が stale だと host ビルドが
  `MRBC_SYMID_fetch undeclared` で落ちる。
  `rm mrbgems/picoruby-mrubyc/lib/mrubyc/src/_autogen_*.h` で再生成させる。

## 対応方針の選択肢

1. mruby/mruby へ上流 PR (mruby-task は上流リポジトリ内にある。picoruby の task scheduler
   全ユーザーに影響するため上流価値が高い)
2. 自分の fork にコミットして picoruby / harucom-os の gitlink を更新
3. 当面パッチ運用

自作 C gem は Ruby へコールバックしない設計 (背景エンジン + Ruby poll) を維持するが、
mruby ランタイム自体の再入 (require / eval / 文字列補間 / core の C yield) は排除できない
ため、恒久対策はこの VM 側ガードになる。
