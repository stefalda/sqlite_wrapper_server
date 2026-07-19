import 'package:inject_x/inject_x.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite_wrapper_sample/services/database_service.dart';

class RegistrationInfo {
  String? email;
  String? token;
  String? refreshToken;

  bool get isRegistered =>
      email != null &&
      email!.isNotEmpty &&
      token != null &&
      token!.isNotEmpty;
}

class RegistrationInfoService {
  late RegistrationInfo registrationInfo;

  Future<RegistrationInfo> getRegistrationInfo() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    registrationInfo = RegistrationInfo()
      ..email = prefs.getString("email")
      ..token = prefs.getString("token")
      ..refreshToken = prefs.getString("refreshToken");
    _setTokenValue();
    return registrationInfo;
  }

  Future<void> setRegistrationInfo() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    prefs.setString("email", registrationInfo.email ?? "");
    prefs.setString("token", registrationInfo.token ?? "");
    prefs.setString("refreshToken", registrationInfo.refreshToken ?? "");
    _setTokenValue();
  }

  Future<void> registerOrLogin(
      {required String email, required String password, login = false}) async {
    final authClient = inject<DatabaseService>().database.authClient;
    final response = login
        ? await authClient.login(email, password)
        : await authClient.register(email, password);
    if (!response.success) {
      throw Exception(response.message);
    }
    registrationInfo
      ..email = email
      ..token = response.token
      ..refreshToken = response.refreshToken;
    await setRegistrationInfo();
  }

  void _setTokenValue() {
    inject<DatabaseService>().database.token = registrationInfo.token ?? "";
  }
}
