// ignore_for_file: prefer_final_fields, avoid_print
import 'package:flutter/material.dart';
import 'dart:async'; 
import 'dart:io'; // 💡 무선 통신 소켓 서버를 위한 필수 부품 추가!

void main() {
  runApp(const SmartControlApp());
}

class SmartControlApp extends StatelessWidget {
  const SmartControlApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Smart Control Center',
      theme: ThemeData(
        brightness: Brightness.dark,
        primaryColor: Colors.blueAccent,
        scaffoldBackgroundColor: const Color(0xFF0F1115),
      ),
      home: const SmartControlScreen(),
    );
  }
}

class SmartControlScreen extends StatelessWidget {
  const SmartControlScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const SmartControlHomeScreen();
  }
}

class SmartControlHomeScreen extends StatefulWidget {
  const SmartControlHomeScreen({super.key});

  @override
  State<SmartControlHomeScreen> createState() => _SmartControlHomeScreenState();
}

class _SmartControlHomeScreenState extends State<SmartControlHomeScreen> {
  String _notifyMode = 'sound'; 
  int _floatCount = 10;
  Color _currentFloatColor = Colors.amberAccent; 
  String _selectedSound = 'sound_1';
  double _brightnessValue = 1.0; 
  double _sensitivityValue = 0.5; 

  List<bool> _floatPowerStates = List.generate(20, (index) => true);

  // 💡 [입질 감지용] 찌가 깜빡거리는 상태를 체크하기 위한 리스트
  List<bool> _floatBiteStates = List.generate(20, (index) => false);

  // 💡 네트워크 서버 변수
  ServerSocket? _serverSocket;
  String _serverIpMessage = "PC IP를 확인하고 폰을 연결해 주세요.";

  @override
  void initState() {
    super.initState();
    _startPCServer(); // 💡 프로그램 켜지자마자 수신 서버 가동!
  }

  @override
  void dispose() {
    _serverSocket?.close(); // 프로그램 꺼질 때 문 안전하게 닫기
    super.dispose();
  }

  // 💡 무선 신호를 받아들이는 수신기(TCP 서버) 로직
  void _startPCServer() async {
    try {
      // 모든 네트워크 카드(anyIPv4)의 8888번 포트를 활짝 열어둡니다.
      _serverSocket = await ServerSocket.bind(InternetAddress.anyIPv4, 8888);
      
      setState(() {
        _serverIpMessage = "서버 가동 중 (포트: 8888) | 스마트폰 접속 대기...";
      });

      // 스마트폰이 접속하면 신호를 읽기 시작합니다.
      _serverSocket!.listen((Socket clientSocket) {
        print('스마트폰(찌)이 제어 본부에 연결되었습니다: ${clientSocket.remoteAddress.address}');
        
        clientSocket.listen((List<int> data) {
          String message = String.fromCharCodes(data).trim();
          print('스마트폰으로부터 받은 신호: $message');

          // 💡 폰에서 "BITE:3" (3번 찌 입질!) 이라는 신호가 오면 반응하기
          if (message.startsWith("BITE:")) {
            int floatNum = int.tryParse(message.split(":")[1]) ?? 1;
            _triggerBiteAlert(floatNum);
          }
        }, onError: (error) {
          print('통신 에러: $error');
          clientSocket.close();
        }, onDone: () {
          print('스마트폰 연결 종료');
          clientSocket.close();
        });
      });

    } catch (e) {
      setState(() {
        _serverIpMessage = "서버 구동 실패: $e";
      });
    }
  }

  // 💡 입질 신호를 받으면 해당 찌를 빨간색으로 번쩍번쩍하게 만드는 마법
  void _triggerBiteAlert(int floatNumber) {
    int index = floatNumber - 1;
    if (index < 0 || index >= 20) return;

    setState(() {
      _floatBiteStates[index] = true; // 입질 상태 On!
    });

    // 3초 동안 번쩍인 후 다시 평화로운 상태로 복귀
    Timer(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() {
          _floatBiteStates[index] = false;
        });
      }
    });
  }

  void _toggleNotifyMode() {
    setState(() {
      switch (_notifyMode) {
        case 'sound': _notifyMode = 'vibrate'; break;
        case 'vibrate': _notifyMode = 'mute'; break;
        case 'mute': _notifyMode = 'sound'; break;
      }
    });
  }

  IconData _getNotifyIcon() {
    switch (_notifyMode) {
      case 'sound': return Icons.volume_up;
      case 'vibrate': return Icons.vibration;
      case 'mute': return Icons.volume_off;
      default: return Icons.volume_up;
    }
  }

  String _getNotifyLabel() {
    switch (_notifyMode) {
      case 'sound': return '소리';
      case 'vibrate': return '진동';
      case 'mute': return '무음';
      default: return '소리';
    }
  }

  void _showCountSelector() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black.withValues(alpha: 0.85),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Container(
              padding: const EdgeInsets.all(20),
              height: 280,
              child: Column(
                children: [
                  const Text('SELECT COUNT', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 1.5, color: Colors.white)),
                  const SizedBox(height: 20),
                  Expanded(
                    child: GridView.builder(
                      itemCount: 20,
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 10, mainAxisSpacing: 8, crossAxisSpacing: 8),
                      itemBuilder: (context, index) {
                        int currentNum = index + 1;
                        bool isSelected = _floatCount == currentNum;
                        return InkWell(
                          onTap: () {
                            setModalState(() => _floatCount = currentNum);
                            setState(() => _floatCount = currentNum);
                            Navigator.pop(context);
                          },
                          child: Container(
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: isSelected ? Colors.blueAccent : Colors.white.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: isSelected ? Colors.blueAccent : Colors.transparent, width: 1.5),
                            ),
                            child: Text('$currentNum', style: TextStyle(color: isSelected ? Colors.white : Colors.white70, fontWeight: FontWeight.bold, fontSize: 13)),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _showColorSelector() {
    final List<Map<String, dynamic>> colors = [
      {'name': '레드', 'color': Colors.redAccent},
      {'name': '그린', 'color': Colors.greenAccent},
      {'name': '블루', 'color': Colors.lightBlueAccent},
      {'name': '옐로우', 'color': Colors.amberAccent},
      {'name': '핑크', 'color': Colors.pinkAccent},
    ];

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black.withValues(alpha: 0.85),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (BuildContext context) {
        return Container(
          padding: const EdgeInsets.all(20),
          height: 200,
          child: Column(
            children: [
              const Text('SELECT COLOR', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 1.5, color: Colors.white)),
              const SizedBox(height: 30),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: colors.map((c) {
                  Color col = c['color'] as Color;
                  bool isSelected = _currentFloatColor == col;
                  return InkWell(
                    onTap: () {
                      setState(() { _currentFloatColor = col; });
                      Navigator.pop(context);
                    },
                    borderRadius: BorderRadius.circular(30),
                    child: Container(
                      width: 50, height: 50,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle, color: col,
                        border: Border.all(color: isSelected ? Colors.white : Colors.transparent, width: 3),
                        boxShadow: isSelected 
                          ? [BoxShadow(color: col.withValues(alpha: 0.8), blurRadius: 15, spreadRadius: 3)] 
                          : [BoxShadow(color: col.withValues(alpha: 0.3), blurRadius: 5)],
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showSoundSelector() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black.withValues(alpha: 0.85),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (BuildContext context) {
        return Container(
          padding: const EdgeInsets.all(20),
          height: 360, 
          child: Column(
            children: [
              const Text('SELECT NOTIFICATION SOUND', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 1.5, color: Colors.white)),
              const SizedBox(height: 10),
              Text('assets/sound/ 폴더 내 파일과 매핑됩니다.', style: TextStyle(fontSize: 11, color: Colors.white.withValues(alpha: 0.4))),
              const SizedBox(height: 15),
              Expanded(
                child: ListView.builder(
                  itemCount: 5, 
                  itemBuilder: (context, index) {
                    String soundName = 'sound_${index + 1}';
                    bool isSelected = _selectedSound == soundName;

                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4.0),
                      child: ListTile(
                        onTap: () {
                          setState(() { _selectedSound = soundName; });
                          Navigator.pop(context); 
                        },
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        tileColor: isSelected ? Colors.blueAccent.withValues(alpha: 0.15) : Colors.white.withValues(alpha: 0.03),
                        leading: Icon(Icons.music_video, color: isSelected ? Colors.blueAccent : Colors.white38),
                        title: Text('알림음 ${index + 1} ($soundName.mp3)', style: TextStyle(color: isSelected ? Colors.blueAccent : Colors.white70, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal, fontSize: 14)),
                        trailing: isSelected ? const Icon(Icons.check_circle, color: Colors.blueAccent) : const Icon(Icons.radio_button_unchecked, color: Colors.white24),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showPairingScanner() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black.withValues(alpha: 0.85),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      isScrollControlled: true, 
      builder: (BuildContext context) {
        return const _PairingScannerWidget(); 
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(child: Image.asset('assets/images/bg_dalchun.jpg', fit: BoxFit.cover)),
            Positioned.fill(child: Container(color: Colors.black.withValues(alpha: 0.3))),
            
            Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(20.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('SMART CONTROL CENTER', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, letterSpacing: 2.0, color: Colors.white, shadows: [Shadow(color: Colors.black54, offset: Offset(1, 2), blurRadius: 4)])),
                          const SizedBox(height: 5),
                          // 💡 상단에 무선 연결 상태 메시지 띄워주기
                          Text(_serverIpMessage, style: TextStyle(fontSize: 12, color: Colors.blueAccent.withValues(alpha: 0.8), fontWeight: FontWeight.bold)),
                        ],
                      ),
                      Row(
                        children: [
                          ElevatedButton(
                            onPressed: () {
                              setState(() {
                                for (int i = 0; i < 20; i++) { _floatPowerStates[i] = true; }
                              });
                            }, 
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent.withValues(alpha: 0.8), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))), 
                            child: const Text('ALL ON', style: TextStyle(color: Colors.white))
                          ),
                          const SizedBox(width: 10),
                          ElevatedButton(
                            onPressed: () {
                              setState(() {
                                for (int i = 0; i < 20; i++) { _floatPowerStates[i] = false; }
                              });
                            }, 
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent.withValues(alpha: 0.8), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))), 
                            child: const Text('ALL OFF', style: TextStyle(color: Colors.white))
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                
                Expanded(
                  child: Center(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal, 
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: List.generate(_floatCount, (index) => _buildKreftFloat(index + 1)),
                      ),
                    ),
                  ),
                ),
                
                Container(
                  height: 180,
                  decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: [Colors.black.withValues(alpha: 0.9), Colors.black.withValues(alpha: 0.3)])),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 40),
                        child: Row(
                          children: [
                            const Icon(Icons.light_mode, color: Colors.amber, size: 20),
                            Expanded(
                              child: Slider(
                                value: _brightnessValue, min: 0.1, max: 1.0,
                                onChanged: (value) { setState(() { _brightnessValue = value; }); },
                                activeColor: Colors.amber, inactiveColor: Colors.amber.withValues(alpha: 0.3)
                              )
                            ),
                            const Icon(Icons.waves, color: Colors.cyanAccent, size: 20),
                            Expanded(
                              child: Slider(
                                value: _sensitivityValue, min: 0.1, max: 1.0,
                                onChanged: (value) { setState(() { _sensitivityValue = value; }); },
                                activeColor: Colors.cyanAccent, inactiveColor: Colors.cyanAccent.withValues(alpha: 0.3)
                              )
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            _BottomMenu(icon: Icons.grid_view, label: '찌선택', onTap: _showCountSelector),
                            _BottomMenu(icon: Icons.palette_outlined, label: '색상', onTap: _showColorSelector),
                            _BottomMenu(icon: Icons.music_note, label: '알림음', onTap: _showSoundSelector),
                            InkWell(
                              onTap: _toggleNotifyMode,
                              borderRadius: BorderRadius.circular(10),
                              child: Container(
                                width: 70, padding: const EdgeInsets.symmetric(vertical: 5),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(_getNotifyIcon(), color: _notifyMode == 'mute' ? Colors.redAccent : Colors.blueAccent, size: 30),
                                    const SizedBox(height: 4),
                                    Text(_getNotifyLabel(), style: TextStyle(color: _notifyMode == 'mute' ? Colors.redAccent : Colors.blueAccent, fontSize: 12, fontWeight: FontWeight.bold)),
                                  ],
                                ),
                              ),
                            ),
                            _BottomMenu(icon: Icons.bluetooth, label: '페어링', onTap: _showPairingScanner),
                          ],
                        ),
                      ),
                      const SizedBox(height: 15),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildKreftFloat(int number) {
    int index = number - 1; 
    bool isOn = _floatPowerStates[index]; 
    bool isBite = _floatBiteStates[index]; // 💡 현재 찌의 입질 상태 여부

    // 기본 색상 정의
    Color ledColor = isOn ? _currentFloatColor.withValues(alpha: _brightnessValue) : Colors.grey.shade900;
    List<BoxShadow>? ledGlow = isOn 
        ? [BoxShadow(color: _currentFloatColor.withValues(alpha: 0.8 * _brightnessValue), blurRadius: 15 * _brightnessValue, spreadRadius: 4 * _brightnessValue)] 
        : null;

    // 💡 폰에서 입질 신호(BITE)가 오면 일시적으로 강력한 발광 레드 컬러로 변경!
    if (isBite && isOn) {
      ledColor = Colors.redAccent;
      ledGlow = [
        const BoxShadow(color: Colors.red, blurRadius: 25, spreadRadius: 8),
        const BoxShadow(color: Colors.white, blurRadius: 10, spreadRadius: 2),
      ];
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 4, height: 20,
            decoration: BoxDecoration(color: ledColor, borderRadius: BorderRadius.circular(2), boxShadow: ledGlow),
          ),
          Container(width: 1.5, height: 3, color: Colors.grey[900]),
          Container(
            width: 2.5, height: 110, 
            decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.black, Colors.redAccent, Colors.black, Colors.redAccent, Colors.black, Colors.redAccent, Colors.black, Colors.redAccent])),
          ),
          
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPress: () {
              setState(() { _floatPowerStates[index] = !_floatPowerStates[index]; });
            },
            child: CustomPaint(size: const Size(22, 100), painter: KreftBodyPainter()),
          ),
          
          Container(width: 1, height: 60, color: Colors.grey[600]),
          const SizedBox(height: 15),
          Container(
            width: 24, height: 24, alignment: Alignment.center,
            decoration: BoxDecoration(shape: BoxShape.circle, color: isBite ? Colors.redAccent : Colors.black.withValues(alpha: 0.6), border: Border.all(color: isBite ? Colors.white : Colors.white30, width: 1)),
            child: Text('$number', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 8),
          Container(
            width: 22, height: 10, padding: const EdgeInsets.all(1.5),
            decoration: BoxDecoration(border: Border.all(color: Colors.white54, width: 1.5), borderRadius: BorderRadius.circular(3)),
            child: Row(children: [Container(width: 14, decoration: BoxDecoration(color: isOn ? Colors.greenAccent : Colors.grey[800], borderRadius: BorderRadius.circular(1)))]), 
          ),
          const SizedBox(height: 10),
        ],
      ),
    );
  }
}

class KreftBodyPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    double width = size.width; double height = size.height; double centerX = width / 2;
    final paint = Paint()
      ..shader = const RadialGradient(center: Alignment(-0.2, -0.4), radius: 1.2, colors: [Color(0xFF444444), Color(0xFF111111), Color(0xFF000000)], stops: [0.0, 0.5, 1.0]).createShader(Rect.fromLTWH(0, 0, width, height))
      ..style = PaintingStyle.fill;
    final path = Path();
    path.moveTo(centerX, 0); 
    path.cubicTo(0, 0, 0, height * 0.2, 0, height * 0.2); 
    path.quadraticBezierTo(0, height * 0.5, centerX - 0.5, height); path.lineTo(centerX + 0.5, height); 
    path.quadraticBezierTo(width, height * 0.5, width, height * 0.2); path.cubicTo(width, height * 0.2, width, 0, centerX, 0);
    path.close();
    canvas.drawPath(path, paint);

    final goldPaint = Paint()..color = Colors.amber.withValues(alpha: 0.2)..style = PaintingStyle.stroke..strokeWidth = 0.5;
    canvas.drawPath(path, goldPaint);

    final textPainter = TextPainter(
      text: const TextSpan(text: "K\nR\nE\nF\nT", style: TextStyle(color: Colors.amber, fontSize: 8.5, fontWeight: FontWeight.bold, height: 1.1, letterSpacing: 1.0)),
      textDirection: TextDirection.ltr, textAlign: TextAlign.center,
    );
    textPainter.layout(); textPainter.paint(canvas, Offset(centerX - (textPainter.width / 2), height * 0.15));
  }
  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _BottomMenu extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  const _BottomMenu({required this.icon, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap, 
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 70, padding: const EdgeInsets.symmetric(vertical: 5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white70, size: 28),
            const SizedBox(height: 5),
            Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

class _PairingScannerWidget extends StatefulWidget {
  const _PairingScannerWidget();
  @override
  State<_PairingScannerWidget> createState() => _PairingScannerWidgetState();
}

class _PairingScannerWidgetState extends State<_PairingScannerWidget> with SingleTickerProviderStateMixin {
  late AnimationController _radarController;
  List<String> _foundDevices = []; 

  @override
  void initState() {
    super.initState();
    _radarController = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat();
    Future.delayed(const Duration(seconds: 1), () { if(mounted) setState(() => _foundDevices.add('KREFT Bobber #1')); });
    Future.delayed(const Duration(seconds: 2), () { if(mounted) setState(() => _foundDevices.add('KREFT Bobber #2')); });
    Future.delayed(const Duration(seconds: 4), () { if(mounted) setState(() => _foundDevices.add('KREFT Bobber #3')); });
  }

  @override
  void dispose() {
    _radarController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      height: 500, 
      child: Column(
        children: [
          const Text('BLUETOOTH PAIRING', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 1.5, color: Colors.white)),
          const SizedBox(height: 5),
          Text('주변의 KREFT 전자찌를 탐색 중입니다...', style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.5))),
          const SizedBox(height: 30),
          Stack(
            alignment: Alignment.center,
            children: [
              Container(width: 120, height: 120, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.blueAccent.withValues(alpha: 0.3), width: 1))),
              Container(width: 80, height: 80, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.blueAccent.withValues(alpha: 0.5), width: 1))),
              RotationTransition(
                turns: _radarController,
                child: Container(
                  width: 120, height: 120,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: SweepGradient(colors: [Colors.blueAccent.withValues(alpha: 0.0), Colors.blueAccent.withValues(alpha: 0.5)], stops: const [0.5, 1.0]),
                  ),
                ),
              ),
              const Icon(Icons.bluetooth_searching, color: Colors.blueAccent, size: 40),
            ],
          ),
          const SizedBox(height: 30),
          Expanded(
            child: _foundDevices.isEmpty 
              ? Center(child: Text('검색 대기 중...', style: TextStyle(color: Colors.white.withValues(alpha: 0.3))))
              : ListView.builder(
                  itemCount: _foundDevices.length,
                  itemBuilder: (context, index) {
                    return ListTile(
                      leading: const Icon(Icons.device_hub, color: Colors.blueAccent),
                      title: Text(_foundDevices[index], style: const TextStyle(color: Colors.white)),
                      subtitle: Text('신호 강도: 훌륭함', style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 11)),
                      trailing: ElevatedButton(
                        onPressed: () {},
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent.withValues(alpha: 0.2), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
                        child: const Text('연결', style: TextStyle(color: Colors.blueAccent)),
                      ),
                    );
                  },
                ),
          ),
        ],
      ),
    );
  }
}