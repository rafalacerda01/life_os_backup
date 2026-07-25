class InputSanitizer {
  // Regex leve para remoção básica de tags HTML
  static final _htmlTagRegExp = RegExp(r'<[^>]*>');

  // Regex de e-mail ligeiramente mais abrangente para TLDs modernos
  static final _emailRegExp = RegExp(
    r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$',
  );

  /// Limpa strings nulas ou com tags maliciosas/espaços extras
  static String sanitize(String? input) {
    if (input == null || input.isEmpty) return '';
    return input.replaceAll(_htmlTagRegExp, '').trim();
  }

  /// Valida o formato estrutural de um e-mail
  static bool isValidEmail(String? email) {
    if (email == null || email.isEmpty) return false;
    return _emailRegExp.hasMatch(email.trim());
  }
}
