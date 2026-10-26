# umbar

umbar, MacBook'un notch'unu çalan müzik, yaklaşan etkinlikler, bir dosya rafı ve ses/parlaklık
göstergeleri için küçük bir panele dönüştürür.

umbar, TheBoredTeam'in [boring.notch](https://github.com/TheBoredTeam/boring.notch) projesinin
GNU General Public License v3.0 ile dağıtılan bir fork'udur. TheBoredTeam ile bağlantılı değildir
ve onlar tarafından desteklenmez. Bkz. [Lisans ve teşekkür](#lisans-ve-teşekkür).

English: [README.md](README.md). Bu dokümanda arayüzdeki adlar (menüler, ayarlar) İngilizce
arayüzdeki halleriyle verilmiştir. İki doküman çelişirse İngilizce olan geçerlidir.

## Özellikler

- **Notch paneli.** Açmak için imleci notch'un üzerine getirin, notch'a tıklayın ya da notch
  üzerinde iki parmakla aşağı kaydırın; kapatmak için yukarı kaydırın. Bekleme süresini, notch yüksekliğini ve dokunsal
  geri bildirimi ayarlardan değiştirebilirsiniz.
- **Müzik.** macOS'ta ne çalıyorsa onun parça bilgisini, kapağını ve kontrollerini gösterir;
  tarayıcı sekmesindeki YouTube Music ve diğer müzikler dahil. Bu yol çalışmazsa umbar kendiliğinden
  Apple Music ve Spotify'a geçer. Hangi kontrollerin görüneceğini seçebilirsiniz (karıştır,
  önceki, oynat/duraklat, sonraki, tekrar, ses, favori, geri sar, ileri sar). Parça değişince
  kapalı notch'ta kısa bir önizleme gösterebilir.
- **Takvim ve Anımsatıcılar.** Haftalık şeritte seçtiğiniz günün etkinliklerini ve zamanlanmış
  anımsatıcılarını gösterir. Varsayılan olarak kapalıdır; **Settings > Calendar**'dan açın.
- **Dosya rafı.** Dosyaları notch'a sürükleyip elinizin altında tutun, sonra ihtiyaç duyduğunuz
  yere sürükleyip bırakın. Sağ tıklayınca Open, Open With, Show in Finder, Quick Look, Share,
  Copy, Copy Path, Rename ve Remove; uygun olduğunda Compress, Create PDF, Convert Image ve
  Remove Background seçenekleri çıkar. Raf yalnızca dosya kabul eder.
- **Sistem HUD'unun yerine geçme.** macOS'un ses, ekran parlaklığı ve klavye aydınlatması
  göstergelerinin yerine notch'ta çizilen göstergeler koyar. Varsayılan olarak kapalıdır;
  Erişilebilirlik (Accessibility) izni gerekir.
- **Pil.** Pil seviyesini ve şarj durumunu gösterir; güç kaynağı değiştiğinde kısa bir bildirim
  verir.
- **Klavye kısayolları.** Notch'u ⌘⇧I ile açıp kapatın, parça önizlemesini ⌘⇧H ile açıp kapatın.
  **Settings > Shortcuts**'tan değiştirebilirsiniz.

umbar'da otomatik güncelleyici yoktur. Bkz. [Güncelleme](#güncelleme).

## Gereksinimler

- macOS 27.0 veya sonrası.
- Notch'lu bir MacBook. Notch'u olmayan bir ekranda (örneğin harici monitör) umbar, ekranın üst
  ortasına notch biçiminde bir panel çizer.

## Kurulum

> [!NOTE]
> Henüz yayımlanmış bir sürüm yok. Bu bölüm, sürümlerin dağıtılacağı Developer ID ile imzalı ve
> notarize edilmiş DMG'yi anlatır. İlk sürüm çıkana kadar [Kaynaktan derleme](#kaynaktan-derleme)
> bölümünü kullanın.

1. umbar DMG'sini bu deponun Releases sayfasından indirin.
2. DMG'yi açın.
3. **umbar**'ı **Applications** klasörüne sürükleyin.
4. DMG'yi çıkarın.
5. **umbar**'ı **Applications** klasöründen açın.

macOS, internetten indirilmiş bir uygulamayı açmak istediğinizi bir kez onaylamanızı ister.
Onaylayın. Ardından umbar kısa bir karşılama ekranı gösterir; bu aşamada hiçbir izin istemez.

Kopyanızın imzalı ve notarize edilmiş sürüm olduğunu kontrol etmek için şunu çalıştırın:

```bash
spctl -a -vv /Applications/umbar.app
```

Beklenen çıktı:

```
/Applications/umbar.app: accepted
source=Notarized Developer ID
origin=Developer ID Application: … (264H2ARX4K)
```

### macOS umbar'ı açmayı reddederse

umbar'ın yayımlanan sürümü notarize edildiği için macOS onu ek bir adım gerektirmeden açar.
macOS uygulamanın hasarlı olduğunu, kötü amaçlı yazılım açısından denetlenemediğini ya da
tanımlanmamış bir geliştiriciden geldiğini söylüyorsa, elinizdeki kopya bizim yayımladığımız kopya
değildir ya da indirildikten sonra değiştirilmiştir.

1. umbar'ın o kopyasını Çöp Sepeti'ne taşıyın.
2. Bu deponun Releases sayfasından yeniden indirin.
3. Uyarı yine çıkarsa uygulamayı açmayın ve bir issue açın.

umbar'ı açmak için quarantine özniteliğini kaldırmayın ve Gatekeeper'ı devre dışı bırakmayın.

### Boring Notch'tan geçiyorsanız

umbar'ın kendi bundle identifier'ı vardır (`com.serhadbahadir.umbar`). Boring Notch'un ayarlarını,
rafını ve izinlerini okumaz; kurulumu ve izinleri yeniden yaparsınız.

## Güncelleme

umbar güncelleme denetimi yapmaz. Güncellemek için:

1. umbar'dan menü çubuğu simgesiyle çıkın (**Quit**).
2. Yeni DMG'yi bu deponun Releases sayfasından indirin.
3. **umbar**'ı **Applications** klasörüne sürükleyin ve eski kopyanın yerine koyun.
4. umbar'ı açın.

Ayarlarınız ve rafınız korunur.

## İzinler

umbar ilk açılışta hiçbir izin istemez. Bir izni, o izne ihtiyaç duyan özelliği ilk kullandığınızda
ister; nedenini açıklar ve macOS'un kendi sorusunu göstermeden önce **Allow Access**'e
tıklamanızı bekler. Reddederseniz yalnızca o özellik çalışmaz.

| İzin | umbar ne zaman sorar | Ne için kullanılır | Reddederseniz |
|---|---|---|---|
| Takvimler (Calendars) | Takvim notch'ta ilk göründüğünde ya da **Settings > Calendar**'da | Etkinliklerinizi notch'ta göstermek için okumak | Etkinlik gösterilmez |
| Anımsatıcılar (Reminders) | Takvim izni açıldıktan sonra etkinliklerin altındaki bir bantta ya da **Settings > Calendar**'da | Zamanlanmış anımsatıcıları etkinliklerin yanında göstermek için okumak | Anımsatıcı gösterilmez |
| Erişilebilirlik (Accessibility) | **Settings > HUDs** içinde **Replace system HUD**'u açtığınızda | Ses ve parlaklık tuşlarını görüp kendi HUD'unu çizmek | HUD değiştirme kapalı kalır; macOS kendi HUD'unu gösterir |
| Otomasyon (Automation): Music, Spotify | umbar o uygulamaya ilk komutu gönderdiğinde macOS sorar | O uygulamadaki parçayı okumak; çalmayı, sesi ve favorileri kontrol etmek | umbar o uygulamayı okuyamaz ve kontrol edemez |

**Now Playing** müzik kaynağı herhangi bir izin istemez.

macOS her izin için kendi sorusunu yalnızca bir kez gösterir. Kararınızı sonradan değiştirmek
için umbar'ın özelliğin yerinde gösterdiği **Open System Settings** düğmesini kullanın ya da
**Sistem Ayarları > Gizlilik ve Güvenlik**'i açıp **Takvimler**, **Anımsatıcılar**,
**Erişilebilirlik** ya da **Otomasyon**'u seçin.

## Gizlilik

umbar'da hesap, analitik ve çökme raporlama yoktur. Sakladığı her şey Mac'inizde kalır.

**Mac'inizde saklananlar**

| Ne | Nerede |
|---|---|
| Ayarlar ve klavye kısayolları | `com.serhadbahadir.umbar` defaults alanı (`~/Library/Preferences/com.serhadbahadir.umbar.plist`) |
| Raftakiler: dosyalarınızın kopyası değil, onlara referanslar | `~/Library/Application Support/com.serhadbahadir.umbar/Shelf/items.json` |
| İndirilen Spotify kapak görselleri, en fazla 100 MB | `~/Library/Caches/com.serhadbahadir.umbar/` |
| Compress ya da Convert Image gibi raf işlemlerinin ürettiği dosyalar (siz sürükleyip çıkarana kadar) | macOS geçici klasörü |

Takvim etkinlikleri ve anımsatıcılar her gösterildiğinde macOS'tan okunur; umbar kopyalarını
saklamaz.

umbar, Mac'inizde kalan macOS birleşik günlüğüne (unified log) tanılama mesajları yazar. Bu
mesajlar rafa koyduğunuz dosyaların yollarını ve çalma durumundaki değişiklikleri içerir.

**Ağ bağlantıları**

- **Albüm kapakları.** umbar kapak görsellerini yalnızca HTTPS üzerinden ve yalnızca Spotify'ın
  görsel sunucularından (`scdn.co` ve `spotifycdn.com`) indirir. Başka adresleri ve başka bir
  adrese yönlendirmeyi reddeder. Now Playing kaynağından ve Apple Music'ten gelen kapaklar
  macOS'tan ve Music uygulamasından gelir, indirme yapılmaz.
- **Özel görselleştiriciler.** **Settings > Appearance**'ta bir Lottie JSON URL'si girerek özel
  görselleştirici eklerseniz, umbar o dosyayı girdiğiniz adresten indirir.

umbar'ın kendi başına yaptığı başka ağ bağlantısı yoktur.

## Kaldırma

1. **Settings > General**'da **Launch at login**'i kapatın.
2. umbar'dan menü çubuğu simgesiyle çıkın (**Quit**).
3. umbar'a verilen izinleri sıfırlayın:

   ```bash
   tccutil reset All com.serhadbahadir.umbar
   ```

   Bunu uygulamayı silmeden önce çalıştırın. Uygulama silindikten sonra `tccutil` onu bulamaz ve
   `No such bundle identifier` yazar.
4. **umbar**'ı **Applications** klasöründen Çöp Sepeti'ne sürükleyin.
5. Ayarlarını silin:

   ```bash
   defaults delete com.serhadbahadir.umbar
   ```

6. Raf verisini ve önbellekleri silin:

   ```bash
   rm -rf ~/Library/Application\ Support/com.serhadbahadir.umbar
   rm -rf ~/Library/Caches/com.serhadbahadir.umbar
   rm -rf ~/Library/HTTPStorages/com.serhadbahadir.umbar
   ```

   Var olmayan bir klasör hata vermeden atlanır.

## Kaynaktan derleme

Gereksinimler: macOS 27.0 veya sonrası ve Xcode 27.0 veya sonrası.

1. Bu depoyu klonlayın ve klasörüne geçin.
2. Projeyi açın:

   ```bash
   open boringNotch.xcodeproj
   ```

3. **boringNotch** scheme'ini seçip ⌘R'ye basın.

Komut satırından derlemek için:

```bash
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Debug build
```

Çıktının son satırı `** BUILD SUCCEEDED **` olur. Yerel derleme ad hoc imzalanır ("Sign to Run
Locally"); Developer ID ile imzalı ya da notarize edilmiş değildir. Derlendiği Mac'te çalışır.

Proje, scheme ve kaynak klasörleri, upstream değişiklikleri birleştirilebilsin diye upstream'in
`boringNotch` adlarını korur. Ürettikleri uygulama `umbar.app`'tir.

## Katkı ve güvenlik

- [CONTRIBUTING.md](CONTRIBUTING.md): hata bildirme ve değişiklik gönderme.
- [SECURITY.md](SECURITY.md): bir güvenlik açığını gizli olarak bildirme.

## Lisans ve teşekkür

umbar, [GNU General Public License v3.0](LICENSE) ile lisanslanmış özgür yazılımdır. Kaynak kodu
bu depodadır.

umbar, TheBoredTeam ve boring.notch katkıcılarının
[boring.notch](https://github.com/TheBoredTeam/boring.notch) projesine dayanır; upstream `main`
dalının `23e7705` (2026-10-18) commit'inden fork edilmiştir. Upstream telif bildirimleri kaynak
dosyalarda korunur. [NOTICE](NOTICE) fork'u kaydeder; o tarihten beri yapılan her değişiklik git
geçmişindedir.

umbar ayrıca şu projelerden kod içerir:

- Jonas van den Berg'in [MediaRemoteAdapter](https://github.com/ungive/mediaremote-adapter)
  projesi (BSD 3-Clause): sistem genelindeki Now Playing kaynağını sağlar.
- Lakr Aream'in [NotchDrop](https://github.com/Lakr233/NotchDrop) projesi (MIT): rafın temeli.
- Carlos César Neves Enumo'nun [Calendr](https://github.com/pakerwreah/Calendr) projesi (MIT).
- Kai Azim'in [DynamicNotchKit](https://github.com/MrKai77/DynamicNotchKit) projesi (MIT).
- Aditya Vaidyam ve katkıcılarının [Parrot](https://github.com/avaidyam/Parrot) projesi (MPL 2.0).

Lisans metinlerinin tamamı [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES) dosyasındadır.
