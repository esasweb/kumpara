/// Mobil API ayarları.
/// Şifreyi (apiSecret) .env veya güvenli bir yerde tutun; production'da
/// bu dosyayı .gitignore'a ekleyip gerçek değeri sadece sizde saklayın.
class AppApi {
  /// Laravel API base URL (sonunda / yok)
  static const String baseUrl = 'https://www.kumpara.com.tr';

  /// API şifresi - Laravel .env'deki MOBILE_API_SECRET ile aynı olmalı.
  /// Kullanıcıların ulaşamayacağı bir yerde tutun; production'da --dart-define
  /// veya başka yöntemle inject edin.
  static const String apiSecret = 'Wn8kL2mPqR5vX9zA4bC7dF1gH3jJ6sT0uY';
}
