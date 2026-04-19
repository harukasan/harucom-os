# Japanese text demo for text mode
#
# Fills the screen with Japanese text containing many unique kanji
# to exercise the per-position glyph bitmap (previously limited to 512
# unique wide characters by the cache).

keyboard = $keyboard
T = DVI::Text
ROWS = T::ROWS
COLS = T::COLS

def wait_key(kb)
  loop do
    c = kb.read_char
    if c
      if c == Keyboard::CTRL_C || c == Keyboard::ESCAPE
        T.clear(0xF0)
        T.commit
        exit
      end
      return c
    end
    T.commit
  end
end

def show_footer(msg, kb)
  T.clear_line(ROWS - 1, 0x8F)
  T.put_string(0, ROWS - 1, msg, 0x8F)
  T.commit
  wait_key(kb)
end

DVI.set_mode(DVI::TEXT_MODE)

# Step 1: Hiragana + Katakana
T.clear(0xF0)
T.put_string(0, 0, "--- ASCII・ひらがな・カタカナ ---", 0x1F)
ascii = "!\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\]^_`abcdefghijklmnopqrstuvwxyz{|}~"
hira = "あいうえおかきくけこさしすせそたちつてとなにぬねの" \
       "はひふへほまみむめもやゆよらりるれろわをん"
kata = "アイウエオカキクケコサシスセソタチツテトナニヌネノ" \
       "ハヒフヘホマミムメモヤユヨラリルレロワヲン"
T.put_string(0, 2, ascii, 0xF0)
T.put_string(0, 4, hira, 0xF0)
T.put_string(0, 6, kata, 0xF0)
show_footer("[1] ASCII / Hiragana / Katakana  Press any key", keyboard)

# Step 2: Many unique kanji (> 512)
# Education kanji (kyouiku kanji) - 1006 characters
T.clear(0xF0)
T.put_string(0, 0, "--- 教育漢字 (1006字) ---", 0x1F)

kanji = "愛悪圧安暗案以位囲委意易異移胃衣遺医域育一印員因引飲院右宇羽雨運雲営映栄永泳英衛液益駅円園延沿演遠塩央往応横王黄億屋恩温音" \
        "下化仮何価加可夏家科果歌河火花荷課貨過我画芽賀会解回快改械海灰界絵開階貝外害街各拡格確覚角閣革学楽額割活株寒刊巻完官干幹感慣漢看管簡観間関館丸岸眼岩顔願" \
        "危喜器基寄希揮机旗期機帰気汽季紀規記貴起技疑義議客逆久休吸宮弓急救求泣球究級給旧牛去居挙許漁魚京供競共協境強教橋胸興郷鏡業局曲極玉勤均禁筋近金銀" \
        "九句区苦具空君訓群軍郡係兄型形径敬景系経計警軽芸劇激欠決潔穴結血月件健券建憲検権犬研絹県見険験元原厳減源現言限個古呼固己庫戸故湖五午後語誤護" \
        "交候光公功効厚口向后好孝工幸広康校構港皇紅耕考航行講鉱鋼降高号合刻告国穀黒骨今困根混左差査砂座再最妻才採済災祭細菜裁際在材罪財坂作昨策桜冊刷察札殺雑皿" \
        "三参山散産算蚕賛酸残仕使司史四士始姉姿子市師志思指支枝止死氏私糸紙至視詞詩試誌資飼歯事似児字寺持時次治磁示耳自辞式識七失室質実舎写射捨社者謝車借尺若弱" \
        "主取守手種酒首受授樹収周宗就州修拾秋終習衆週集住十従縦重宿祝縮熟出術述春準純順処初所暑署書諸助女序除傷勝商唱将小少承招昭松消焼照省章笑証象賞障上乗城場常情条状蒸植織職色食" \
        "信心新森深申真神臣親身進針人仁図垂推水数寸世制勢性成政整星晴正清生盛精聖声製西誠青静税席昔石積績責赤切接折設節説雪絶舌先千宣専川戦泉浅洗染線船選銭前善然全" \
        "祖素組創倉奏層想操早巣争相窓総草装走送像増臓蔵造側則息束測足速属族続卒存孫尊損村他多太打体対帯待態貸退隊代台大第題宅達谷単担探炭短誕団断暖段男談値知地池置築竹茶着" \
        "中仲宙忠昼柱注虫著貯丁兆帳庁張朝潮町腸調長頂鳥直賃追痛通低停定底庭弟提程敵的笛適鉄典天展店転点伝田電徒登都努度土党冬刀島投東湯灯当等答糖統討豆頭働動同堂導童道銅得徳特毒独読届" \
        "内南難二肉日乳入任認熱年念燃納能脳農波派破馬俳拝敗背肺配倍梅買売博白麦箱畑八発判半反板版犯班飯晩番否悲批比皮秘肥費非飛備美鼻必筆百俵標氷票表評病秒品貧" \
        "不付夫婦富布府父負武部風副復服福腹複仏物分奮粉文聞兵平並閉陛米別変片編辺返便勉弁保歩補墓暮母包報宝放方法訪豊亡忘暴望棒貿防北牧本妹枚毎幕末万満味未密脈民務夢無" \
        "名命明盟迷鳴綿面模毛木目問門夜野矢役約薬訳油輸優勇友有由遊郵夕予余預幼容曜様洋用羊葉要陽養欲浴翌来落乱卵覧利理裏里陸律率立略流留旅両料良量領力緑林臨輪類令例冷礼歴列練連路労朗老六録論和話"

row = 2
col = 0
kanji.each_char do |ch|
  if col + 2 > COLS
    col = 0
    row += 1
  end
  break if row >= ROWS - 1
  T.put_string(col, row, ch, 0xF0)
  col += 2
end
show_footer("[2] 1006 education kanji  Press any key", keyboard)

# Step 3: Mixed ASCII + Japanese with colors
T.clear(0x00)
T.put_string(0, 0, "--- Mixed Content ---", 0x0F)

colors = [0x0F, 0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x90, 0xA0]
lines = [
  "Harucom OS テキストモード表示テスト",
  "The quick brown fox jumps over the lazy dog.",
  "色々な漢字を表示できます",
  "ひらがなカタカナABC混在テスト123",
  "プログラミング言語 Ruby で動いています",
  "解像度: 640x480 文字数: 106x37",
  "半角文字と全角文字の混在表示確認",
  "吾輩は猫である。名前はまだ無い。",
  "どこで生れたかとんと見当がつかぬ。",
  "何でも薄暗いじめじめした所でニャーニャー泣いていた事だけは記憶している。",
  "吾輩はここで始めて人間というものを見た。",
  "しかもあとで聞くとそれは書生という人間中で一番獰悪な種族であったそうだ。",
  "この書生というのは時々我々を捕えて煮て食うという話である。",
  "しかしその当時は何という考もなかったから別段恐しいとも思わなかった。",
  "ただ彼の掌に載せられてスーと持ち上げられた時何だかフワフワした感じがあったばかりである。",
  "掌の上で少し落ちついて書生の顔を見たのがいわゆる人間というものの見始であろう。",
  "この時妙なものだと思った感じが今でも残っている。",
  "第一毛をもって装飾されべきはずの顔がつるつるしてまるで薬缶だ。",
]
lines.each_with_index do |line, i|
  break if i + 2 >= ROWS - 1
  T.put_string(0, i + 2, line, colors[i % colors.length])
end
show_footer("[3] Mixed ASCII + JP + colors  Press any key", keyboard)

# Step 4: Scroll stress test with Japanese text
T.clear(0xF0)
T.put_string(0, 0, "--- Scroll Test ---", 0x1F)
T.commit

120.times do |i|
  T.scroll_up(1, 0xF0)
  msg = "スクロール行 #{i}: 日本語テキストの連続表示テスト"
  T.put_string(0, ROWS - 2, msg, 0xF0)
  T.commit
end
show_footer("[4] Scroll test done  Press any key", keyboard)

# Step 5: Bold text
T.clear(0xF0)
T.put_string(0, 0, "--- Bold Text ---", 0x1F)
T.put_string(0, 2, "Normal: ABCabc 012 あいうえお", 0xF0)
T.put_string_bold(0, 3, "Bold:   ABCabc 012 あいうえお", 0xF0)
T.put_string(0, 5, "Normal: 漢字表示テスト", 0xF0)
T.put_string_bold(0, 6, "Bold:   漢字表示テスト", 0xF0)
show_footer("[5] Bold text  Press any key", keyboard)

# Done
T.clear(0xF0)
T.commit
