# Spike C4: Kulak çakışması algılama (menü bar öğeleri ve notch)

- **Kart:** #107 (Can tasarım incelemesi C4 ve açık soru 3, `docs/reviews/can-design-review-2026-10-26.md`). Eş kartlar: #106 (AC-1.8 yedek davranış, Furkan), #108 (çene tasarımı, Hüsna)
- **Tarih:** 2026-10-26
- **Makineler:** Mac mini `Mac16,10` + LG UltraWide 2560 × 1080 (notch yok), MacBook Air `Mac14,2` (gerçek notch, 2048 × 1332 pt "Daha fazla alan" ölçeği, pilde). İkisi de macOS 27.0.1 (26A434)
- **İmza:** ad-hoc + Hardened Runtime, umbar'ın `boringNotch.entitlements` dosyasıyla (A2 ile aynı profil)
- **İzinler:** probe'da **Screen Recording yok, Accessibility yok** (iki makinede `CGPreflightScreenCaptureAccess() == false`, `AXIsProcessTrusted() == false`). Bu, umbar'ın temiz kurulumdaki hali.
- **Yazan:** Emrullah

## Sonuç

**NO-GO**: izin olmadan çakışmayı güvenilir şekilde algılamak mümkün değil. **GO**: notch geometrisi, saf karar fonksiyonu ve AX izni varsa AX ile ölçüm. Sonuç olarak **çene yedeği zorunlu**, isteğe bağlı bir ek değil.

1. **`CGWindowListCopyWindowInfo` ile status item sınırı okunamıyor. Bunun Screen Recording ile ilgisi yok.** macOS 27.0.1'de status item'lar ayrı pencere değil. Bütün menü bar `MenuBarAgent` sürecinin tam genişlikteki layer-24 pencerelerinde çiziliyor, ayrıca `Window Server` "Menubar" penceresi var. Probe'un kendi 30 status item'ı bile listede **hiç** görünmedi (`ownWindowsInCGWindowList.count == 0`). `NSWindow.windowNumber` değerleri 2³²'nin katları, yani sahte/uzak numaralar (E2, E5). Can'ın notundaki ikinci yol (C4: "CGWindowList ile status item sınırları") bu sürümde **geçersiz**.
2. **İzinsiz CGWindowList, owner ve bounds döndürüyor. Başlıklar Screen Recording istiyor.** 126–128 pencerenin hepsinde owner, pid, layer ve bounds geldi. `kCGWindowName` yalnızca `Window Server` ve `WindowManager` pencerelerinde vardı (6 pencere). Diğer bütün başlıklar `nil`. Açık soru 3'ün CGWindowList yarısının cevabı bu, ama 1. madde yüzünden bu bilgi işe yaramıyor.
3. **AXMenuBar / AXExtrasMenuBar ancak Accessibility izniyle okunuyor.** İzinsiz her çağrı `kAXErrorAPIDisabled (-25211)` döndürüyor: ön plandaki uygulamanın `AXMenuBar`'ı, ControlCenter / SystemUIServer / MenuBarAgent `AXExtrasMenuBar`'ı ve sistem genelindeki hit-test. Hata 24–45 µs içinde dönüyor, yani bloklamıyor (E3). İzinli yol **bu spike'ta ölçülemedi**: iki makinede de izin yok ve izin vermek kullanıcı arayüzü gerektiriyor. Ön plandaki uygulamanın menü başlıklarını (sol kulak) okumanın **tek** yolu AX.
4. **`NSScreen.auxiliaryTopLeftArea/RightArea` izinsiz çalışıyor, doğru ve ucuz.** Air'de notch 250 × 45 pt ve x = 899…1149. Kulaklar 45 × 45 (E1). Mac mini'de iki alan da `nil` ve `safeAreaInsets.top == 0`.
5. **Ölçülen yeni bilgi: macOS, notch'un sağına ~44 pt'den fazla yaklaşan status item'ları gizliyor.** Air'de bar dolunca görünen en soldaki status item `x = 1193`'te başladı (notch.maxX + 44). `x = 1192`'ye düşecek öğe gizlendi (E5). Sağ kulak 1149…1194. Yani **dolu bir status bar sağ kulakla en fazla 1 pt çakışıyor.** Bu bir garanti değil, bir gözlem: tek makinede ve tek ölçekte. Görünürlük de çerçeve düzeninden çıkarıldı, ekrana bakılarak değil. Ama sağ kulak genişliği `H − 5` (~40 pt) olsaydı, bu yapılandırmada görünür bir status item'a hiç değmezdi. Gizlenen öğeler ekran dışına değil, **kulak bölgesinin içine** "park ediliyor": hepsi aynı çerçevede, x = 1154…1184. Saf bir AX toplayıcı bu yüzden yanlış pozitif üretebilir (E5, aşağıda "Toplayıcı kuralları").
6. **Maliyet sorun değil.** NSScreen + geometri 100–150 µs, CGWindowList 104–165 µs (p50), `AXIsProcessTrusted` < 1 µs, karar fonksiyonu 40 dikdörtgende 1,5 µs (E6). İzinli AX okumasının maliyeti ölçülmedi.

## Kabul kriterine cevaplar (kart #107)

| Soru | Cevap | Kanıt |
|---|---|---|
| Çakışma Screen Recording izni olmadan algılanabiliyor mu? | **Hayır.** Status item'lar CGWindowList'te hiç yok, SR olsa da olmasa da. Menü başlıkları için tek yol AX, o da Accessibility istiyor. SR olmadan izinsiz bilinebilen tek şey notch geometrisi. | E2, E3, E5 |
| Açık soru 3: AXMenuBar çerçeveleri ve CGWindowList status item sınırları SR olmadan okunuyor mu? | **AXMenuBar:** SR gerekmiyor ama **Accessibility** gerekiyor. İzinsiz `-25211`. **CGWindowList:** bounds ve owner SR olmadan geliyor, başlıklar gelmiyor. Status item sınırı ise hiç yok. | E2, E3 |
| Güvenilirlik | İzinsiz: çakışma ölçülemiyor. Karar `UnmeasuredMenuBarPolicy` ile verilmek zorunda. AX ile: kod hazır, **doğrulanmadı**. Gizli öğelerin park edilmesi (5. madde) ve status alanının kayması (aynı oturumda sağ kenar 1472 → 1439, saat genişliği) dikkate alınmalı. | E3, E5 |
| Maliyet | Olay başına < 0,5 ms (izinsiz yol). Polling gerekmiyor. | E6 |
| Çene tetik koşulu | Aşağıda, #108 önerisi. | |

## #108 için öneri (Hüsna, Furkan #106)

1. **Çene birinci sınıf bir yerleşim olmalı.** Kullanıcıların çoğunda umbar'ın Accessibility izni olmayacak (izin yalnızca HUD için isteniyor). Bu kullanıcılarda AC-1.8 yalnızca çene ile **garanti** edilebilir.
2. **Tetik koşulu** (`MenuBarCollision.placement`, kodda):
   - Ölçülen bir menü başlığı ya da status item, kulak + 4 pt boşluk bölgesine pozitif alanla giriyorsa → **çene**. Bu, eksik ölçümde de geçerli.
   - Ölçüm tamsa ve çakışma yoksa → **kulak**.
   - Ölçüm eksikse (AX yok) → `UnmeasuredMenuBarPolicy`. **Bu bir ürün kararı (Furkan, #106).** Benim önerim: AX yoksa `.assumeOccupied` (hep çene), çünkü AC-1.8 kesin ifadeli. Diğer seçenek `.assumeFree` (kulak, en iyi çaba). Bu durumda AC-1.8 yumuşatılmalı.
3. **Kulak genişliği için tasarım önerisi:** sağ kulak çizimi `H` yerine `H − 5` (Air'de 40 pt) olursa, ölçülen yapılandırmada görünür status item'lara izinsiz bile değmez (5. madde). Sol kulak için (uygulama menüleri) böyle bir veri yok. Bu yüzden önerim, **izinsiz modda kulak yalnızca sağda**, sol yuva içeriği (albüm kapağı vb.) çeneye insin. Bu öneri Habibe'nin görsel doğrulamasından ve başka bir ölçekte (varsayılan 1470 × 956) tekrarlanmasından önce **kabul edilmemeli**.
4. **Ne zaman yeniden hesaplanır (polling yok):**
   - kapalı ada kulak gerektiren bir etkinliğe geçerken (talep anında, < 0,5 ms),
   - `NSWorkspace.didActivateApplicationNotification` (ön plandaki uygulama, yani menü başlıkları değişti),
   - `NSApplication.didChangeScreenParametersNotification` (çözünürlük, ekran ekleme/çıkarma, ana ekran değişikliği).

   Status item ekleme/çıkarma için bildirim yok. AX varken kulak görünürken düşük frekansta (ör. 10–30 sn) bir tazeleme yeterli. AX yoksa ölçülecek bir şey yok, tazeleme de yok.
5. **Titreme olmasın:** yerleşim görünürken en fazla etkinlik başlangıcında ve uygulama değişiminde değişsin. Status alanı kendiliğinden kayıyor (saat genişliği: E5'te aynı oturumda 33 pt), bu yüzden her tazelemede kulak ↔ çene geçişi yapılmamalı.
6. **Notch'suz ekranlar:** `NotchGeometry.make` `nil` döner. Çağıran, adanın çizdiği dikdörtgeni "sanal notch" olarak verip aynı kuralı kullanır (test: `virtualNotchOnAScreenWithoutOneUsesTheSameRule`).
7. **Tam ekran / gizli menü bar:** test edilmedi (ayar değiştirmek kullanıcı ayarına dokunmak olurdu). Air'de `_HIHideMenuBar` ve `AppleMenuBarVisibleInFullscreen` anahtarları yok, yani varsayılan değerler geçerli (yalnızca tam ekranda gizlen). Gizli bar üzerine imleçle gelince açılır ve kulakla çakışabilir. Öneri: `NSMenu.menuBarVisible() == false` iken ada notch-only kalsın. Doğrulama Habibe'de.

## Kanıt

Bütün ölçümler `Tools/MenuBarProbe` ile alındı. Bu, `open -n -W` ile başlatılan bir LSUIElement `.app`. Bu sayede TCC kararını shell ya da sshd değil probe'un kendisi alıyor (A2'deki gerekçe). Probe, uygulamanın derlediği `boringNotch/private/MenuBarGeometry/MenuBarCollision.swift` dosyasını aynen derliyor. Çıktı JSON-lines. Pencere başlıkları yalnızca layer 24/25'te kaydedildi, bunlar sistem dizgileri ("Menubar").

### E1: Ekran geometrisi (`screens`)

```
Air:  frame 2048×1332, visibleFrame.h 1286, menuBarThickness 46, safeAreaTop 45
      auxLeft  {x 0,    y 1287, w 899, h 45}   auxRight {x 1149, y 1287, w 899, h 45}
      → notch CG {x 899, y 0, w 250, h 45}; leftEar {x 854, w 45}; rightEar {x 1149, w 45}
mini: LG ULTRAWIDE 2560×1080, menuBarThickness 30, safeAreaTop 0, auxLeft/Right nil → notch nil
NSStatusBar.system.thickness = 22 on both (not the real 30/46 bar height; do not use it)
```

İki ölçüm arasında değer değişmedi (`screens` ve `screens2` aynı). `NSScreen.h`, yardımcı alanların hangi koordinat uzayında olduğunu söylemiyor. Air'in yerleşik ekranı orijinde olduğu için iki yorum burada aynı sonucu veriyor. `NotchGeometry.make` ikisini de kabul ediyor (TODO, #107).

### E2: CGWindowList, izinsiz (`windows`)

```
permissions → screenRecording false, accessibility false
summary (Air)  total 126, withName 6, withNameOwners ["Window Server","WindowManager"]
summary (mini) total 128, withName 6, withNameOwners ["Window Server","WindowManager"]
layer 24: Window Server "Menubar" 2048×46 (×3), MenuBarAgent <nil> 2048×46 (×3)     (Air)
layer 25: none in the menu bar strip on either machine (mini's two layer-25 windows are
          app panels at y 33 / y 893, not status items)
layer 0:  every regular app owns off-screen 2048×46 (Air) / 2560×30 (mini) windows at y 0
```

Menü bar şeridinde öğe boyutunda tek bir pencere bile yok.

### E3: Accessibility, izinsiz (`ax`)

```
frontmost com.apple.Terminal (Air) / com.apple.loginwindow (mini, ekran kilitli)
axMenuBar  (frontmost)            → apiDisabled(-25211)
axExtras   controlcenter          → apiDisabled(-25211)
axExtras   systemuiserver         → apiDisabled(-25211)
axExtras   MenuBarAgent           → apiDisabled(-25211)
axHitTest  left / right ear centre → apiDisabled(-25211)
```

Hiçbir çağrı izin istemi açmadı. Probe yalnızca `AXIsProcessTrusted()` kullanıyor, `...WithOptions(prompt)` hiç çağrılmadı.

### E4: İzinli AX yolu

**Ölçülmedi.** İki makinede de umbar ya da probe için Accessibility izni yok. İzin vermek System Settings'te tıklama gerektiriyor, bu da bu spike'ın kapsamı dışında. `axBarFrames` (probe) kodu hazır: her AX çağrısına 0,25 sn mesaj zaman aşımı koyuyor, böylece donmuş bir uygulama umbar'ın main thread'ini durduramaz. Doğrulama protokolü "Açık kalanlar" bölümünde.

### E5: Status item yerleşimi, probe'un kendi boş öğeleriyle (`statusitems`)

Öğeler başlıksız (boş). Tıklanmadı. Her koşudan sonra `removeStatusItem` ile kaldırıldı.

```
mini, 3 × length 24  → window frames x 1969 / 1929 / 1889, w 40 (length + 16 pt padding)
Air,  3 × length 24  → x 1432 / 1392 / 1352 (user's items start at 1472)
Air,  length 0       → w 16 (a zero-length item still takes 16 pt; no invisible sentinel)
Air, 30 × length 24  → x 1432 … 1232 (6 visible), then 18 items parked at x 1184,
                       6 items at {0, -46} with screen nil
Air, 60 × length 4   → leftmost visible x 1212 (would-be 1192 parked at 1184)
Air, 20 × length 15  → … 1224, 1193 visible; rest parked at 1154
Air, 20 × length 7   → leftmost visible 1196; parked at 1165
Air, 20 × length 5   → leftmost visible 1199; parked at 1170
Air, 20 × length 6   → leftmost visible 1208 (would-be 1186 parked at 1178)
Air, 20 × length 4   → leftmost visible 1199; parked at 1171  (user's items now start at 1439)
```

Görünür alt sınır: **1192 < x_min ≤ 1193**, yani notch.maxX'in 44 pt sağı. "Görünür" bir çıkarım: Air'in ekranı görülemedi. Tek başına bir çerçevesi olan öğe görünür, başka öğelerle aynı çerçeveyi paylaşan öğe gizli kabul edildi. Ekran görüntüsüyle doğrulanmadı. `NSStatusItem.isVisible` park edilen öğelerde de `true`. Bu özellik kullanıcının tercihini gösteriyor, yerleşimi değil. Park edilenleri ayırt etmenin tek işareti, aynı çerçeveyi paylaşmaları. `decisionOnOwnItems` 30 öğe denemesinde park edilen öğeler yüzünden "chin" dedi. Toplayıcı onları elemezse kural haklı ama yanlış nedenle çene seçer.

Sol taraf (uygulama menüleri) ölçülemedi: kendi menüsünü göstermek için probe'un ön plana geçmesi, yani kullanıcının uygulamasından odağı alması gerekirdi.

### E6: Maliyet (`bench`, 200 tekrar, µs)

| Ölçüm | mini p50 / p95 / max | Air p50 / p95 / max |
|---|---|---|
| `NSScreen.screens` + `NotchGeometry.make` | 102 / 133 / 169 | 150 / 174 / 219 |
| `CGWindowListCopyWindowInfo(onScreenOnly)` | 165 / 369 / 1758 | 104 / 137 / 2222 |
| `AXIsProcessTrusted()` | 0,3 / 0,4 / 2,3 | 0,5 / 0,6 / 2,7 |
| AX menü bar okuma (izinsiz, hata yolu) | 24 / 40 / 6089 | 45 / 50 / 7387 |
| `MenuBarCollision.placement` (40 dikdörtgen) | n/a (notch yok) | 1,5 / 1,5 / 3,1 |

### E7: Bildirimler (`watch`)

8 sn pasif dinlemede olay gelmedi. Bu sırada probe'un ikinci bir örneği başlatıldı, ama LSUIElement uygulamaları için `didLaunchApplication` gönderilmiyor. `NSMenu.menuBarVisible()` iki uçta da `true`. Uygulama aktivasyonu tetiklenmedi, çünkü bu kullanıcının uygulamasına dokunmak olurdu. Yani bildirim stratejisi **belgelenmiş API'ye dayanıyor, bu spike'ta çalıştırılmadı.**

## Kod

- `boringNotch/private/MenuBarGeometry/MenuBarCollision.swift`: yalnızca CoreGraphics, yan etkisiz.
  - `NotchGeometry.make(...)`: NSScreen değerlerinden global CG uzayında notch ve kulaklar.
  - `MenuBarOccupancy { occupied, isComplete }`: "ölçülemedi" ile "boş" asla karışmasın diye.
  - `MenuBarCollision.placement(geometry:occupancy:policy:clearance:) -> .ears / .chin`: üç değerli kural.
  - `MenuBarCollision.collisions(...)`: loglama için çakışan dikdörtgenler.
- `umbarTests/MenuBarCollisionTests.swift`: 21 test. Fikstürler E1/E5 değerleri.
- `Tools/MenuBarProbe/`: probe (`build.sh <out-dir>`, `main.swift`, `Info.plist`).

Toplayıcı (AX okuyucu) uygulamaya **konmadı**. İzinli yolu doğrulanmamış kodu uygulama hedefine sokmak istemedim. Probe'daki `axBarFrames` başlangıç noktası. Toplayıcı kuralları:

- `AXIsProcessTrusted() == false` → `MenuBarOccupancy.unknown`. İzin istemi hiçbir zaman buradan açılmaz.
- Her AX öğesine `AXUIElementSetMessagingTimeout(…, 0.25)`. Hata ya da zaman aşımı → `isComplete = false`.
- Aynı çerçeveyi paylaşan status item'lar park edilmiş sayılır ve elenir (E5). Bunun AX'te de böyle göründüğü doğrulanmadı.
- Notch altındaki dikdörtgenler kurala zaten girmiyor. Yalnızca kulak bölgesine uzananlar sayılıyor.

## Entegrasyon notu: pbxproj

`umbarTests` hostless bir hedef ve test ettiği uygulama kaynaklarını `project.pbxproj`'deki bir membership listesinden alıyor. Bu dalda pbxproj'e dokunulmadı (kart kuralı). Bu yüzden **`umbarTests` bu dalda olduğu haliyle derlenmiyor** (`cannot find 'NotchGeometry' in scope`, doğrulandı). Birleştirmeden önce pbxproj sahibi şu satırı eklemeli:

```diff
 				EyeBreak/EyeBreakEngine.swift,
+				MenuBarGeometry/MenuBarCollision.swift,
 			);
 			target = A1837B1361C7F96E52B64318 /* umbarTests */;
```

Bu satır eklenmiş bir kopyada `scripts/test.sh` çalıştırıldı: **TEST SUCCEEDED**, 172 test geçti, bunların 21'i yeni. Uygulama hedefi (`boringNotch` şeması) değişiklik olmadan derleniyor, çünkü klasör senkronize: **BUILD SUCCEEDED**. Yeni dosyalarda uyarı yok.

## Açık kalanlar

1. **İzinli AX doğrulaması** (Habibe ya da kullanıcı, Air'de, ekranı görerek): probe'a Accessibility izni verilir. `ax` modu Xcode ön plandayken (uzun menüler) ve bar doluyken çalıştırılır. Ölçülecekler: (a) menü başlığı çerçeveleri gerçek konumla eşleşiyor mu, (b) status item'lar hangi sürecin `AXExtrasMenuBar`'ında, (c) park edilen öğeler AX'te nasıl görünüyor, (d) okuma maliyeti. Bunun ardından izin kaldırılır.
2. **Sol taraf eşiği:** macOS, uygulama menülerini notch'un soluna ne kadar yaklaştırıyor? Ölçülmedi (E5 son paragraf).
3. **Başka ölçekler:** 44 pt eşiği yalnızca 2048 × 1332 ölçeğinde ölçüldü. Varsayılan 1470 × 956'da da tekrarlanmalı (H ve eşik ölçekle değişiyor olabilir).
4. **Yardımcı alan koordinat uzayı:** harici birincil ekranlı bir notch'lu Mac'te doğrulanmalı (kod TODO'su).
5. **Ürün kararı (Furkan, #106):** AX yokken `UnmeasuredMenuBarPolicy` `.assumeOccupied` mı olacak, `.assumeFree` mi? AC-1.8 buna göre yazılmalı.
