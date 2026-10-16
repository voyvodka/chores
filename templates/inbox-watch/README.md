# inbox-watch — gelen kutusu özeti

Bir Gmail kutusuna gelen mailleri günde iki kez (09:00, 17:00) okur, yalnızca **gerçekten aksiyon
gerektirenleri** Chores'ta raporlar. Aksiyon yoksa sessiz geçer; varsa bildirim gelir, raporda her
mailin tek cümlelik "ne yapılmalı" açıklaması ve Gmail linki olur.

- **Gmail:** salt okunur izin. Mail silinmez, taşınmaz, okundu yapılmaz.
- **Claude:** kendi Claude Code aboneliğin (`claude -p`), varsayılan model Haiku. Ek ücret yok,
  kotadan çalışma başına kuruşluk bir pay gider. Claude'un hiçbir aracı yoktur; sadece mail metnini
  okur ve sınıflandırır.
- **Ne gönderilir:** son çalışmadan beri gelen maillerin başlıkları ve temizlenmiş metninin ilk
  2000 karakteri. Gelen kutusu ve spam okunur, promosyon ve sosyal sekmeleri atlanır.

## Kurulum (her kişi kendi Mac'inde)

Ön koşul: Chores kurulu (`scripts/install.sh`), Claude Code kurulu ve giriş yapılmış.

1. Ekipten `client_secret_….json` dosyasını al (aşağıdaki "Google tarafı" bir kez yapılır).
2. Çalıştır:

   ```bash
   templates/inbox-watch/setup.sh --client ~/Downloads/client_secret_….json
   ```

3. Tarayıcıda Google hesabını seç. **"Google bu uygulamayı doğrulamadı"** ekranı çıkar — bu
   beklenen durum: *Gelişmiş › (uygulama adı)'na git* ile devam et. İzin ekranında **Gmail
   kutucuğunun işaretli** olduğundan emin ol.
4. Birden fazla Claude hesabın varsa setup hangi sırayla deneneceğini sorar.

Bitti: Chores menüsünde "Gelen kutusu" görünür. Hemen denemek için `chores run inbox-watch`.

Setup güvenle tekrar çalıştırılabilir (repo güncellenince de aynı komut): kendi ayarlarına
(`config.json`), son okuma zamanına (`state.json`) ve kurallarına (`rules.md`) dokunmaz.

## Kendi kuralların

`~/.local/share/chores/jobs/inbox-watch/rules.md` — düz Türkçe, satır başına bir tercih:

```
- Yeni cihazdan giriş bildirimlerini yoksay, girişleri biz yapıyoruz.
- X firmasının faturaları her zaman acil.
- Y'nin haftalık raporlarını hiç gösterme.
```

Model ve metin sınırı `config.json` içinde: `"model": "haiku"` (kaçırdığı olursa `"sonnet"`),
`"maxChars": 2000`.

## Sorun çıkarsa

| Chores'ta görünen | Ne yapmalı |
|---|---|
| Gmail bağlantısı düştü | `setup.sh --reconnect`. Kutunun şifresi değişince Google bütün bağlantıları kapatır; herkes bir kez yapmalı |
| Gmail'e ulaşılamadı | Log'a bak. İnternet yoksa bir sonraki çalışma telafi eder; `403` ise Gmail API projede kapalı demektir |
| Claude yanıt vermedi | Kota dolmuş ya da oturum düşmüş olabilir: `claude` ile giriş yap. O mailler bir sonraki çalışmada tekrar okunur |
| Kurulum yapılmamış | `setup.sh` |

## Google tarafı (bir kez, kutunun sahibi hesapla)

Kutunun kendi Google hesabıyla <https://console.cloud.google.com> üzerinde:

1. **Proje oluştur** (ör. `inbox-watch`).
2. **Gmail API'yi aç:** *API'ler ve Hizmetler › Kitaplık › Gmail API › Etkinleştir*.
3. **Google Auth Platform › Branding:** uygulama adı ve destek e-postası. *Audience:* **External**.
4. **Data Access › Add or Remove Scopes:** `https://www.googleapis.com/auth/gmail.readonly` ekle, kaydet.
5. **Clients › Create Client:** tür **Desktop app**. Oluşturunca JSON'u **hemen indir** — Google
   secret'ı yalnızca bu anda gösteriyor.
6. **Audience › Publish app:** uygulamayı **In production** yap. Doğrulama başvurusu gerekmez.
   *Testing*'de bırakılırsa bağlantı her 7 günde bir düşer.

JSON dosyasını ekiple özelden paylaş; depoya koyma. Setup onu Keychain'e alır, sonra dosya silinebilir.

Bilinmesi gerekenler:
- Doğrulanmamış uygulama ömür boyu en fazla 100 farklı Google hesabına izin verebilir. Aynı kutuyu
  bağlayan her Mac tek hesap sayılır.
- Kutu hesabında **Gelişmiş Koruma** açılırsa doğrulanmamış uygulamalar engellenir.
- Mail içerikleri Claude hesabın üzerinden Anthropic'e gider. claude.ai › Ayarlar › Gizlilik'te
  "modeli geliştirmeye yardım et" seçeneğini kapatmak isteyebilirsin.
