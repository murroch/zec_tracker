import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Инициализируем фоновую службу перед запуском приложения
  await initializeBackgroundService();
  
  runApp(const ZecPremiumApp());
}

// Настройка фоновой службы (Background)
Future<void> initializeBackgroundService() async {
  final service = FlutterBackgroundService();

  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'zec_foreground_id', 
    'ZEC Background Service',
    description: 'Этот канал удерживает приложение в фоне для проверки курса',
    importance: Importance.low, 
  );

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: true,
      isForegroundMode: true, 
      notificationChannelId: 'zec_foreground_id',
      initialNotificationTitle: 'ZEC Трекер',
      initialNotificationContent: 'Мониторинг курса запущен в фоне...',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: true,
      onForeground: onStart,
      onBackground: onIosBackground,
    ),
  );
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  return true;
}

// Код фоновой службы
@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  
  FlutterLocalNotificationsPlugin bgNotifications = FlutterLocalNotificationsPlugin();
  var androidInit = const AndroidInitializationSettings('@mipmap/ic_launcher');
  await bgNotifications.initialize(InitializationSettings(android: androidInit));

  // Функция запроса для фона
  Future<void> fetchPrice() async {
    try {
      final response = await http.get(Uri.parse(
          'https://api.crypto.com/v2/public/get-ticker?instrument_name=ZEC_USDT'));
      
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        double price = double.parse(data['result']['data'][0]['a'].toString());

        final prefs = await SharedPreferences.getInstance();
        double low = double.tryParse(prefs.getString('low') ?? "") ?? 0;
        double high = double.tryParse(prefs.getString('high') ?? "") ?? 999999;

        // Отправляем цену в UI
        service.invoke('updatePrice', {'price': price});

        if (price <= low && low != 0) {
          _showBgNotification(bgNotifications, "ZEC упал! Цена: \$$price");
        } else if (price >= high && high != 0) {
          _showBgNotification(bgNotifications, "ZEC вырос! Цена: \$$price");
        }
      }
    } catch (e) {
      debugPrint("Фоновая ошибка сети: $e");
    }
  }

  // Запускаем сразу при старте службы
  fetchPrice();

  // И повторно каждые 60 секунд
  Timer.periodic(const Duration(seconds: 60), (timer) async {
    await fetchPrice();
  });
}

Future<void> _showBgNotification(FlutterLocalNotificationsPlugin nodPlugin, String message) async {
  var details = const NotificationDetails(
    android: AndroidNotificationDetails('zec_id', 'ZEC Alerts', importance: Importance.max, priority: Priority.high),
    iOS: DarwinNotificationDetails(),
  );
  await nodPlugin.show(1, 'ZEC Premium (Фон)', message, details);
}


class ZecPremiumApp extends StatelessWidget {
  const ZecPremiumApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0A0E17),
      ),
      home: const PremiumTrackerScreen(),
    );
  }
}

class PremiumTrackerScreen extends StatefulWidget {
  const PremiumTrackerScreen({super.key});

  @override
  _PremiumTrackerScreenState createState() => _PremiumTrackerScreenState();
}

class _PremiumTrackerScreenState extends State<PremiumTrackerScreen> with SingleTickerProviderStateMixin {
  double currentPrice = 0.0;
  bool isLoading = true; // Переменная для отслеживания первой загрузки
  final lowController = TextEditingController();
  final highController = TextEditingController();
  late AnimationController _pulseController;
  Timer? _uiTimer;
  FlutterLocalNotificationsPlugin notifications = FlutterLocalNotificationsPlugin();

  @override
  void initState() {
    super.initState();
    _initNotifications();
    _loadSettings();
    _startUiPriceCheck();
    
    FlutterBackgroundService().on('updatePrice').listen((event) {
      if (event != null && mounted) {
        setState(() {
          currentPrice = event['price'];
          isLoading = false; // Данные пришли из фона — скрываем загрузку
        });
      }
    });
    
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
  }

  void _initNotifications() async {
    var android = const AndroidInitializationSettings('@mipmap/ic_launcher');
    var ios = const DarwinInitializationSettings();
    await notifications.initialize(InitializationSettings(android: android, iOS: ios));
  }

  void _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      lowController.text = prefs.getString('low') ?? "";
      highController.text = prefs.getString('high') ?? "";
    });
  }

  void _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('low', lowController.text);
    await prefs.setString('high', highController.text);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text("Лимиты обновлены"),
        backgroundColor: Colors.orangeAccent.withOpacity(0.8),
      ),
    );
  }

  // Запрос цены по таймеру для открытого экрана (раз в 10 секунд)
  Future<void> _fetchPriceForUi() async {
    try {
      final response = await http.get(Uri.parse(
          'https://api.crypto.com/v2/public/get-ticker?instrument_name=ZEC_USDT'));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        double price = double.parse(data['result']['data'][0]['a'].toString());
        
        if (mounted) {
          setState(() {
            currentPrice = price;
            isLoading = false; // Данные успешно загружены!
          });
          _checkAlerts();
        }
      }
    } catch (e) {
      debugPrint("Ошибка сети в приложении: $e");
    }
  }

  void _checkAlerts() {
    double low = double.tryParse(lowController.text) ?? 0;
    double high = double.tryParse(highController.text) ?? 999999;

    if (currentPrice <= low && low != 0) {
      _showNotification("ZEC упал! Цена: \$$currentPrice");
    } else if (currentPrice >= high && high != 0) {
      _showNotification("ZEC вырос! Цена: \$$currentPrice");
    }
  }

  Future<void> _showNotification(String message) async {
    var details = const NotificationDetails(
      android: AndroidNotificationDetails('zec_id', 'ZEC Alerts', importance: Importance.max, priority: Priority.high),
      iOS: DarwinNotificationDetails(),
    );
    await notifications.show(0, 'ZEC Premium', message, details);
  }

  void _startUiPriceCheck() {
    _fetchPriceForUi(); 
    _uiTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      _fetchPriceForUi();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(0, -0.3),
                radius: 1.2,
                colors: [Color(0xFF1A2235), Color(0xFF0A0E17)],
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                _buildHeader(),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Column(
                      children: [
                        const SizedBox(height: 60),
                        _buildPriceDisplay(),
                        const SizedBox(height: 60),
                        _buildGlassCard("Уведомление если упадет до:", lowController, Icons.arrow_downward),
                        const SizedBox(height: 20),
                        _buildGlassCard("Уведомление если поднимется до:", highController, Icons.arrow_upward),
                        const SizedBox(height: 40),
                        _buildGradientButton(),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text("ТЕСТ", 
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: Colors.white70)),
          Row(
            children: [
              FadeTransition(
                opacity: _pulseController,
                child: Container(
                  width: 8, height: 8,
                  decoration: const BoxDecoration(color: Colors.greenAccent, shape: BoxShape.circle),
                ),
              ),
              const SizedBox(width: 8),
              const Text("LIVE 10s", style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPriceDisplay() {
    return Column(
      children: [
        const Text("Курс сейчас ZEC (Crypto.com):", 
          style: TextStyle(fontSize: 18, color: Colors.white54, letterSpacing: 1.2)),
        const SizedBox(height: 16),
        // Если идёт загрузка — показываем текст "Загрузка...", если данные есть — красивую цену
        isLoading 
        ? const SizedBox(
            height: 100,
            child: Center(
              child: Text(
                "Загрузка...",
                style: TextStyle(fontSize: 32, color: Colors.white38, fontWeight: FontWeight.w300),
              ),
            ),
          )
        : Text(
            "\$${currentPrice.toStringAsFixed(2)}",
            style: TextStyle(
              fontSize: 72,
              fontWeight: FontWeight.bold,
              letterSpacing: -2,
              color: const Color(0xFFFF9F43),
              shadows: [
                Shadow(blurRadius: 30, color: const Color(0xFFFF9F43).withOpacity(0.5)),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildGlassCard(String title, TextEditingController controller, IconData icon) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.05),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white.withOpacity(0.1)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 16, color: Colors.orangeAccent),
                  const SizedBox(width: 8),
                  Text(title, style: const TextStyle(color: Colors.white60, fontSize: 14)),
                ],
              ),
              TextField(
                controller: controller,
                keyboardType: TextInputType.number,
                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                decoration: const InputDecoration(
                  hintText: "0.00",
                  prefixText: "\$ ",
                  border: InputBorder.none,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGradientButton() {
    return GestureDetector(
      onTap: _saveSettings,
      child: Container(
        width: double.infinity,
        height: 60,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(30),
          gradient: const LinearGradient(
            colors: [Color(0xFFFF9F43), Color(0xFFFFD700)],
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFFF9F43).withOpacity(0.3),
              blurRadius: 20,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: const Center(
          child: Text(
            "Сохранить лимиты",
            style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 16, letterSpacing: 1.1),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _uiTimer?.cancel();
    _pulseController.dispose();
    super.dispose();
  }
}
