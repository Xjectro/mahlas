# Mahlas

**Her açılış, yeni bir kimlik.** Mahlas, Mac'inde tek tıkla temiz ve izole bir sanal Mac açar. Sanal Mac'in tüm trafiği Mullvad VPN tünelinden geçer; içeride ne yapılırsa yapılsın, tünel dışına hiçbir şey çıkmaz. Kapattığında sanal Mac'in diski silinir.

## Kurulum ve ilk açılış

1. `Mahlas.dmg` dosyasını aç ve **Mahlas**'ı **Applications** (Uygulamalar) klasörüne sürükle.
2. Uygulama Apple tarafından imzalanmadığı için macOS ilk açılışta engeller. **Terminal**'i açıp şu komutu çalıştır:

   ```sh
   xattr -dr com.apple.quarantine /Applications/Mahlas.app
   ```

   Ardından Mahlas'ı normal şekilde aç. Bu komut yalnızca bir kez gerekir.

   Terminal kullanmak istemezsen: Mahlas'ı bir kez açmayı dene, sonra **Sistem Ayarları → Gizlilik ve Güvenlik** bölümünün altındaki **Yine de Aç** düğmesine bas.

3. Uygulamadaki **Kurulum** sekmesindeki üç adımı izle:
   1. **Mullvad:** 16 haneli hesap numaranı gir. Mahlas yeni bir WireGuard anahtarı üretir ve hesabına cihaz olarak ekler.
   2. **macOS imajı:** Mahlas, Apple'ın resmi macOS geri yükleme imajını doğrudan Apple'dan indirir (~17 GB) ve sanal diske kurar.
   3. **İlk açılış:** Sanal Mac bir kez açılır. Kurulum Yardımcısı'nı tamamla (Apple hesabıyla giriş yapma), sonra Finder'da **My Shared Files** klasöründeki **Mahlas Kurulum.command** dosyasına çift tıkla. Sanal Mac kapanır ve imaj mühürlenir.

Bundan sonra her **Yeni Kimlikle Başlat** tek tıktır.

### Gereksinimler

- Apple Silicon (M serisi) Mac
- macOS 15 veya üstü
- Mullvad VPN hesabı
- En az ~40 GB boş alan (imaj + sanal disk; disk seyrektir, yalnızca kullanılan alanı kaplar)

## Nasıl çalışır

```
┌──────────────────────── Mahlas.app ──────────────────────────────┐
│                                                                  │
│  macOS misafiri  ══ sanal kablo ══  Ağ geçidi (Alpine Linux)     │
│  (temiz klon,       (yalnızca bu      eth1: DHCP + DNS           │
│   yeni kimlik)       iki VM arası)    wg0 : Mullvad WireGuard ═══╪══▶ Mullvad ──▶ İnternet
│                                       eth0: yalnızca şifreli UDP │
└──────────────────────────────────────────────────────────────────┘
```

İki sanal makine de Apple'ın **Virtualization.framework**'üyle donanım hızında çalışır. Docker veya başka bir yazılım gerekmez.

### Gizlilik modeli

- **Tek çıkış Mullvad tüneli.** Sanal Mac'in tek ağ bağlantısı, ağ geçidi VM'ine giden sanal bir kablodur. Ana Mac'in ağına, yerel ağa ya da modeme erişemez.
- **Kill switch.** Ağ geçidinin güvenlik duvarı her şeyi varsayılan olarak düşürür. Dışarıya yalnızca seçilen Mullvad sunucusuna giden şifreli WireGuard paketlerine izin verir. Tünel düşerse internet kesilir.
- **DNS sızıntısı yok.** Ad çözümleme yalnızca Mullvad'ın tünel içindeki DNS sunucusundan (10.64.0.1) yapılır.
- **IPv6 kapalı**, IPv6 trafiği de düşürülür.
- **Çevrimdışı ağ geçidi.** Ağ geçidinin bütün paketleri, Alpine'in imzalı paket diziniyle birlikte açılış diskine gömülüdür. Ağ geçidi açılırken internete çıkmaz; WireGuard el sıkışması dışında hiçbir şey göndermez.
- **Anahtar diske yazılmaz.** WireGuard özel anahtarı Keychain'de durur ve yalnızca ağ geçidinin belleğine aktarılır. İstersen her oturumda yenilenir, böylece oturumlar Mullvad tarafında birbirine bağlanamaz.
- **Her oturum yeni bir bilgisayar.** Her başlatışta şunlar rastgele seçilir: makine kimliği (seri numarası/ECID), MAC adresi (gerçek Apple üretici kodlarıyla), bilgisayar adı, işlemci ve bellek miktarı, ekran çözünürlüğü, Mullvad çıkış şehri ve sunucusu, buna uygun saat dilimi.
- **İz kalmaz.** Her oturum, mühürlü imajın anlık bir APFS klonudur. Kapatıldığında disk silinir.
- **Kapalı donanım.** Mikrofon, kamera ve USB aktarımı yoktur. Paylaşılan klasör oturumlarda salt okunurdur.
- **Sertleştirilmiş misafir.** Güvenlik duvarı ve gizli mod açıktır, Bonjour yayını ve tanılama verisi gönderimi kapalıdır.

### Neyi koruyamaz

- Sanal Mac içinde kendi hesaplarına giriş yaparsan, o servisler seni tanır.
- İnternet sağlayıcın Mullvad'a bağlandığını görür (içeriği göremez). Trafiğin Mullvad'dan çıkar.
- Mahlas'ın kendisi, ana Mac'te Mullvad ve Apple sunucularıyla konuşur: cihaz kaydı, sunucu listesi ve macOS indirmesi için.

### Mahlas'ın sana veya geliştiriciye gönderdiği veri

Hiçbiri. Mahlas'ın sunucusu, hesabı veya telemetrisi yoktur. Her kullanıcı kendi Mullvad hesabını kullanır, macOS'u doğrudan Apple'dan indirir. Tüm veriler kullanıcının kendi Mac'inde kalır:

- `~/Library/Application Support/Mahlas/`: sanal diskler, ağ geçidi dosyaları, paylaşılan klasör
- Keychain (`com.mahlas.app`): Mullvad hesap numarası ve WireGuard anahtarı

## Lisanslar

- Arayüz yazı tipi: [Unbounded](https://fonts.google.com/specimen/Unbounded) (SIL Open Font License)
- Ağ geçidi: [Alpine Linux](https://alpinelinux.org) paketleri, ilk kurulumda Alpine'in resmi deposundan indirilir.
- macOS, Apple'ın lisans koşulları kapsamında kullanıcı tarafından Apple'dan indirilir. Apple, Apple donanımında aynı anda en fazla iki macOS sanal makinesine izin verir.
