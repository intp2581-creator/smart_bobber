// ignore_for_file: prefer_final_fields, avoid_print
import 'package:flutter/material.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';

// BLE UUIDs
final _serviceUUID     = UUID.fromString('0000FFE0-0000-1000-8000-00805F9B34FB');
final _biteCharUUID    = UUID.fromString('0000FFE1-0000-1000-8000-00805F9B34FB');
final _commandCharUUID = UUID.fromString('0000FFE2-0000-1000-8000-00805F9B34FB');

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
      home: const SmartControlHomeScreen(),
    );
  }
}

class SmartControlHomeScreen extends StatefulWidget {
  const SmartControlHomeScreen({super.key});

  @override
  State<SmartControlHomeScreen> createState() => _SmartControlHomeScreenState();
}

// 연결된 전자찌 정보
class _FloatDevice {
  final Peripheral peripheral;
  GATTCharacteristic? commandChar;
  bool isOn = true;
  bool isBite = false;

  _FloatDevice(this.peripheral);
}

class _SmartControlHomeScreenState extends State<SmartControlHomeScreen> {
  String _notifyMode = 'sound';
  int _floatCount = 10;
  Color _currentFloatColor = Colors.amberAccent;
  String _selectedSound = 'sound_1';
  double _brightnessValue = 1.0;
  double _sensitivityValue = 0.5;

  // 슬롯별 전원 상태 (BLE 연결되지 않은 슬롯도 표시용)
  List<bool> _floatPowerStates = List.generate(20, (_) => true);
  List<bool> _floatBiteStates = List.generate(20, (_) => false);

  // BLE
  final _central = CentralManager();
  // 슬롯 번호(1~20) → 연결된 찌 디바이스
  final Map<int, _FloatDevice> _connectedFloats = {};
  String _bleStatus = 'BLE 초기화 중...';
  bool _isScanning = false;

  StreamSubscription? _bleStateSub;
  StreamSubscription? _discoverySub;
  StreamSubscription? _connStateSub;
  StreamSubscription? _notifySub;

  @override
  void initState() {
    super.initState();
    _initBle();
  }

  @override
  void dispose() {
    _bleStateSub?.cancel();
    _discoverySub?.cancel();
    _connStateSub?.cancel();
    _notifySub?.cancel();
    _central.stopDiscovery();
    super.dispose();
  }

  Future<void> _initBle() async {
    _bleStateSub = _central.stateChanged.listen((args) {
      if (args.state == BluetoothLowEnergyState.poweredOn) {
        setState(() => _bleStatus = '준비됨 — 페어링에서 전자찌 검색');
      }
    });

    // 입질 알림 수신
    _notifySub = _central.characteristicNotified.listen((args) {
      final msg = utf8.decode(args.value);
      if (msg == 'BITE') {
        final slot = _slotOf(args.peripheral);
        if (slot != null) _triggerBiteAlert(slot);
      }
    });

    // 연결/해제 감지
    _connStateSub = _central.connectionStateChanged.listen((args) async {
      if (args.state == ConnectionState.connected) {
        await _onFloatConnected(args.peripheral);
      } else {
        _onFloatDisconnected(args.peripheral);
      }
    });

    final state = await _central.getState();
    if (state == BluetoothLowEnergyState.poweredOn) {
      setState(() => _bleStatus = '준비됨 — 페어링에서 전자찌 검색');
    }
  }

  int? _slotOf(Peripheral p) {
    for (final entry in _connectedFloats.entries) {
      if (entry.value.peripheral.uuid == p.uuid) return entry.key;
    }
    return null;
  }

  Future<void> _onFloatConnected(Peripheral peripheral) async {
    try {
      // 빈 슬롯 찾기
      int slot = 1;
      while (_connectedFloats.containsKey(slot) && slot <= 20) slot++;
      if (slot > 20) return;

      final device = _FloatDevice(peripheral);
      _connectedFloats[slot] = device;

      // GATT 탐색
      final services = await _central.discoverGATT(peripheral);
      for (final svc in services) {
        if (svc.uuid == _serviceUUID) {
          for (final chr in svc.characteristics) {
            if (chr.uuid == _biteCharUUID) {
              await _central.setCharacteristicNotifyState(
                  peripheral, chr, state: true);
            }
            if (chr.uuid == _commandCharUUID) {
              device.commandChar = chr;
            }
          }
        }
      }

      // 현재 설정값 전송
      await _sendSettings(device);

      setState(() => _bleStatus = '${_connectedFloats.length}개 연결됨');
    } catch (e) {
      print('연결 처리 오류: $e');
    }
  }

  void _onFloatDisconnected(Peripheral peripheral) {
    final slot = _slotOf(peripheral);
    if (slot != null) {
      setState(() {
        _connectedFloats.remove(slot);
        _floatBiteStates[slot - 1] = false;
        _bleStatus = _connectedFloats.isEmpty
            ? '준비됨 — 페어링에서 전자찌 검색'
            : '${_connectedFloats.length}개 연결됨';
      });
    }
  }

  Future<void> _sendSettings(_FloatDevice device) async {
    if (device.commandChar == null) return;
    final chr = device.commandChar!;
    final p = device.peripheral;
    final r = _currentFloatColor.r.round();
    final g = _currentFloatColor.g.round();
    final b = _currentFloatColor.b.round();

    final cmds = [
      device.isOn ? 'ON' : 'OFF',
      'COLOR:$r,$g,$b',
      'BRIGHTNESS:${_brightnessValue.toStringAsFixed(2)}',
      'SENSITIVITY:${(_sensitivityValue * 5 + 1).toStringAsFixed(1)}',
    ];

    for (final cmd in cmds) {
      await _central.writeCharacteristic(
        p,
        chr,
        value: Uint8List.fromList(utf8.encode(cmd)),
        withoutResponse: true,
      );
    }
  }

  Future<void> _sendCommandToAll(String cmd) async {
    for (final device in _connectedFloats.values) {
      if (device.commandChar == null) continue;
      try {
        await _central.writeCharacteristic(
          device.peripheral,
          device.commandChar!,
          value: Uint8List.fromList(utf8.encode(cmd)),
          withoutResponse: true,
        );
      } catch (e) {
        print('명령 전송 오류: $e');
      }
    }
  }

  Future<void> _sendCommandToSlot(int slot, String cmd) async {
    final device = _connectedFloats[slot];
    if (device?.commandChar == null) return;
    try {
      await _central.writeCharacteristic(
        device!.peripheral,
        device.commandChar!,
        value: Uint8List.fromList(utf8.encode(cmd)),
        withoutResponse: true,
      );
    } catch (e) {
      print('개별 명령 전송 오류: $e');
    }
  }

  void _triggerBiteAlert(int slot) {
    int index = slot - 1;
    if (index < 0 || index >= 20) return;
    setState(() => _floatBiteStates[index] = true);
    Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _floatBiteStates[index] = false);
    });
  }

  void _toggleNotifyMode() {
    setState(() {
      switch (_notifyMode) {
        case 'sound':   _notifyMode = 'vibrate'; break;
        case 'vibrate': _notifyMode = 'mute';    break;
        case 'mute':    _notifyMode = 'sound';   break;
      }
    });
  }

  IconData _getNotifyIcon() {
    switch (_notifyMode) {
      case 'sound':   return Icons.volume_up;
      case 'vibrate': return Icons.vibration;
      default:        return Icons.volume_off;
    }
  }

  String _getNotifyLabel() {
    switch (_notifyMode) {
      case 'sound':   return '소리';
      case 'vibrate': return '진동';
      default:        return '무음';
    }
  }

  void _showCountSelector() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black.withValues(alpha: 0.85),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => Container(
          padding: const EdgeInsets.all(20),
          height: 280,
          child: Column(
            children: [
              const Text('SELECT COUNT',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5,
                      color: Colors.white)),
              const SizedBox(height: 20),
              Expanded(
                child: GridView.builder(
                  itemCount: 20,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 10, mainAxisSpacing: 8, crossAxisSpacing: 8),
                  itemBuilder: (ctx, i) {
                    final n = i + 1;
                    final sel = _floatCount == n;
                    return InkWell(
                      onTap: () {
                        setModal(() => _floatCount = n);
                        setState(() => _floatCount = n);
                        Navigator.pop(ctx);
                      },
                      child: Container(
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: sel ? Colors.blueAccent : Colors.white.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: sel ? Colors.blueAccent : Colors.transparent, width: 1.5),
                        ),
                        child: Text('$n',
                            style: TextStyle(
                                color: sel ? Colors.white : Colors.white70,
                                fontWeight: FontWeight.bold,
                                fontSize: 13)),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showColorSelector() {
    final colors = [
      {'name': '레드',   'color': Colors.redAccent,       'r': 255, 'g': 0,   'b': 0},
      {'name': '그린',   'color': Colors.greenAccent,     'r': 0,   'g': 255, 'b': 100},
      {'name': '블루',   'color': Colors.lightBlueAccent, 'r': 0,   'g': 200, 'b': 255},
      {'name': '옐로우', 'color': Colors.amberAccent,     'r': 255, 'g': 200, 'b': 0},
      {'name': '핑크',   'color': Colors.pinkAccent,      'r': 255, 'g': 0,   'b': 150},
    ];

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black.withValues(alpha: 0.85),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(20),
        height: 200,
        child: Column(
          children: [
            const Text('SELECT COLOR',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.5,
                    color: Colors.white)),
            const SizedBox(height: 30),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: colors.map((c) {
                final col = c['color'] as Color;
                final sel = _currentFloatColor == col;
                return InkWell(
                  onTap: () {
                    setState(() => _currentFloatColor = col);
                    final cmd =
                        'COLOR:${c['r']},${c['g']},${c['b']}';
                    _sendCommandToAll(cmd);
                    Navigator.pop(ctx);
                  },
                  borderRadius: BorderRadius.circular(30),
                  child: Container(
                    width: 50,
                    height: 50,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: col,
                      border: Border.all(
                          color: sel ? Colors.white : Colors.transparent, width: 3),
                      boxShadow: sel
                          ? [BoxShadow(
                              color: col.withValues(alpha: 0.8),
                              blurRadius: 15,
                              spreadRadius: 3)]
                          : [BoxShadow(
                              color: col.withValues(alpha: 0.3), blurRadius: 5)],
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  void _showSoundSelector() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black.withValues(alpha: 0.85),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(20),
        height: 360,
        child: Column(
          children: [
            const Text('SELECT NOTIFICATION SOUND',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.5,
                    color: Colors.white)),
            const SizedBox(height: 10),
            Text('assets/sound/ 폴더 내 파일과 매핑됩니다.',
                style: TextStyle(
                    fontSize: 11, color: Colors.white.withValues(alpha: 0.4))),
            const SizedBox(height: 15),
            Expanded(
              child: ListView.builder(
                itemCount: 5,
                itemBuilder: (ctx, i) {
                  final name = 'sound_${i + 1}';
                  final sel = _selectedSound == name;
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: ListTile(
                      onTap: () {
                        setState(() => _selectedSound = name);
                        Navigator.pop(ctx);
                      },
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                      tileColor: sel
                          ? Colors.blueAccent.withValues(alpha: 0.15)
                          : Colors.white.withValues(alpha: 0.03),
                      leading: Icon(Icons.music_video,
                          color: sel ? Colors.blueAccent : Colors.white38),
                      title: Text('알림음 ${i + 1} ($name.mp3)',
                          style: TextStyle(
                              color: sel ? Colors.blueAccent : Colors.white70,
                              fontWeight:
                                  sel ? FontWeight.bold : FontWeight.normal,
                              fontSize: 14)),
                      trailing: sel
                          ? const Icon(Icons.check_circle,
                              color: Colors.blueAccent)
                          : const Icon(Icons.radio_button_unchecked,
                              color: Colors.white24),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showPairingScanner() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black.withValues(alpha: 0.85),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      isScrollControlled: true,
      builder: (ctx) => _PairingScannerWidget(
        central: _central,
        serviceUUID: _serviceUUID,
        onConnect: (peripheral) async {
          Navigator.pop(ctx);
          await _central.connect(peripheral);
        },
        connectedUUIDs: _connectedFloats.values
            .map((d) => d.peripheral.uuid)
            .toSet(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
                child: Image.asset('assets/images/bg_dalchun.jpg',
                    fit: BoxFit.cover)),
            Positioned.fill(
                child: Container(
                    color: Colors.black.withValues(alpha: 0.3))),
            Column(
              children: [
                // 상단 헤더
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('SMART CONTROL CENTER',
                              style: TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 2,
                                  color: Colors.white,
                                  shadows: [
                                    Shadow(
                                        color: Colors.black54,
                                        offset: Offset(1, 2),
                                        blurRadius: 4)
                                  ])),
                          const SizedBox(height: 5),
                          Row(
                            children: [
                              Icon(
                                _connectedFloats.isEmpty
                                    ? Icons.bluetooth_disabled
                                    : Icons.bluetooth_connected,
                                color: _connectedFloats.isEmpty
                                    ? Colors.white38
                                    : Colors.blueAccent,
                                size: 14,
                              ),
                              const SizedBox(width: 4),
                              Text(_bleStatus,
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.blueAccent
                                          .withValues(alpha: 0.8),
                                      fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ],
                      ),
                      Row(
                        children: [
                          ElevatedButton(
                            onPressed: () {
                              setState(() {
                                for (int i = 0; i < 20; i++) {
                                  _floatPowerStates[i] = true;
                                }
                                for (final device in _connectedFloats.values) {
                                  device.isOn = true;
                                }
                              });
                              _sendCommandToAll('ON');
                            },
                            style: ElevatedButton.styleFrom(
                                backgroundColor:
                                    Colors.blueAccent.withValues(alpha: 0.8),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(20))),
                            child: const Text('ALL ON',
                                style: TextStyle(color: Colors.white)),
                          ),
                          const SizedBox(width: 10),
                          ElevatedButton(
                            onPressed: () {
                              setState(() {
                                for (int i = 0; i < 20; i++) {
                                  _floatPowerStates[i] = false;
                                }
                                for (final device in _connectedFloats.values) {
                                  device.isOn = false;
                                }
                              });
                              _sendCommandToAll('OFF');
                            },
                            style: ElevatedButton.styleFrom(
                                backgroundColor:
                                    Colors.redAccent.withValues(alpha: 0.8),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(20))),
                            child: const Text('ALL OFF',
                                style: TextStyle(color: Colors.white)),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // 찌 목록
                Expanded(
                  child: Center(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      padding:
                          const EdgeInsets.symmetric(horizontal: 20),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: List.generate(
                            _floatCount, (i) => _buildKreftFloat(i + 1)),
                      ),
                    ),
                  ),
                ),

                // 하단 컨트롤
                Container(
                  height: 180,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.9),
                        Colors.black.withValues(alpha: 0.3),
                      ],
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      // 밝기 & 감도 슬라이더
                      Padding(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 40),
                        child: Row(
                          children: [
                            const Icon(Icons.light_mode,
                                color: Colors.amber, size: 20),
                            Expanded(
                              child: Slider(
                                value: _brightnessValue,
                                min: 0.1,
                                max: 1.0,
                                onChanged: (v) {
                                  setState(
                                      () => _brightnessValue = v);
                                },
                                onChangeEnd: (v) {
                                  _sendCommandToAll(
                                      'BRIGHTNESS:${v.toStringAsFixed(2)}');
                                },
                                activeColor: Colors.amber,
                                inactiveColor:
                                    Colors.amber.withValues(alpha: 0.3),
                              ),
                            ),
                            const Icon(Icons.waves,
                                color: Colors.cyanAccent, size: 20),
                            Expanded(
                              child: Slider(
                                value: _sensitivityValue,
                                min: 0.1,
                                max: 1.0,
                                onChanged: (v) {
                                  setState(
                                      () => _sensitivityValue = v);
                                },
                                onChangeEnd: (v) {
                                  final threshold =
                                      (v * 5 + 1).toStringAsFixed(1);
                                  _sendCommandToAll(
                                      'SENSITIVITY:$threshold');
                                },
                                activeColor: Colors.cyanAccent,
                                inactiveColor: Colors.cyanAccent
                                    .withValues(alpha: 0.3),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),

                      // 하단 버튼
                      Padding(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 10),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            _BottomMenu(
                                icon: Icons.grid_view,
                                label: '찌선택',
                                onTap: _showCountSelector),
                            _BottomMenu(
                                icon: Icons.palette_outlined,
                                label: '색상',
                                onTap: _showColorSelector),
                            _BottomMenu(
                                icon: Icons.music_note,
                                label: '알림음',
                                onTap: _showSoundSelector),
                            InkWell(
                              onTap: _toggleNotifyMode,
                              borderRadius: BorderRadius.circular(10),
                              child: Container(
                                width: 70,
                                padding: const EdgeInsets.symmetric(
                                    vertical: 5),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(_getNotifyIcon(),
                                        color: _notifyMode == 'mute'
                                            ? Colors.redAccent
                                            : Colors.blueAccent,
                                        size: 30),
                                    const SizedBox(height: 4),
                                    Text(_getNotifyLabel(),
                                        style: TextStyle(
                                            color: _notifyMode == 'mute'
                                                ? Colors.redAccent
                                                : Colors.blueAccent,
                                            fontSize: 12,
                                            fontWeight:
                                                FontWeight.bold)),
                                  ],
                                ),
                              ),
                            ),
                            _BottomMenu(
                                icon: Icons.bluetooth,
                                label: '페어링',
                                onTap: _showPairingScanner),
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
    final index = number - 1;
    final connected = _connectedFloats.containsKey(number);
    final isOn = _floatPowerStates[index];
    final isBite = _floatBiteStates[index];

    Color ledColor = isOn
        ? _currentFloatColor.withValues(alpha: _brightnessValue)
        : Colors.grey.shade900;
    List<BoxShadow>? ledGlow = isOn
        ? [
            BoxShadow(
                color: _currentFloatColor
                    .withValues(alpha: 0.8 * _brightnessValue),
                blurRadius: 15 * _brightnessValue,
                spreadRadius: 4 * _brightnessValue)
          ]
        : null;

    if (isBite && isOn) {
      ledColor = Colors.redAccent;
      ledGlow = [
        const BoxShadow(color: Colors.red, blurRadius: 25, spreadRadius: 8),
        const BoxShadow(color: Colors.white, blurRadius: 10, spreadRadius: 2),
      ];
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // 연결 상태 표시
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: connected ? Colors.blueAccent : Colors.transparent,
            ),
          ),
          const SizedBox(height: 4),
          // 케미
          Container(
            width: 4,
            height: 20,
            decoration: BoxDecoration(
                color: ledColor,
                borderRadius: BorderRadius.circular(2),
                boxShadow: ledGlow),
          ),
          Container(width: 1.5, height: 3, color: Colors.grey[900]),
          // 찌탑
          Container(
            width: 2.5,
            height: 110,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black, Colors.redAccent,
                  Colors.black, Colors.redAccent,
                  Colors.black, Colors.redAccent,
                  Colors.black, Colors.redAccent,
                ],
              ),
            ),
          ),
          // 몸통 (롱프레스로 개별 ON/OFF)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPress: () {
              final newState = !_floatPowerStates[index];
              setState(() => _floatPowerStates[index] = newState);
              if (connected) {
                _connectedFloats[number]!.isOn = newState;
                _sendCommandToSlot(number, newState ? 'ON' : 'OFF');
              }
            },
            child: CustomPaint(
                size: const Size(22, 100), painter: KreftBodyPainter()),
          ),
          Container(width: 1, height: 60, color: Colors.grey[600]),
          const SizedBox(height: 15),
          // 번호 뱃지
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isBite
                  ? Colors.redAccent
                  : Colors.black.withValues(alpha: 0.6),
              border: Border.all(
                  color: isBite ? Colors.white : Colors.white30, width: 1),
            ),
            child: Text('$number',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 8),
          // 배터리 바 (전원 상태)
          Container(
            width: 22,
            height: 10,
            padding: const EdgeInsets.all(1.5),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white54, width: 1.5),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Row(
              children: [
                Container(
                  width: 14,
                  decoration: BoxDecoration(
                    color: isOn ? Colors.greenAccent : Colors.grey[800],
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
        ],
      ),
    );
  }
}

// 하단 메뉴 버튼
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
        width: 70,
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white70, size: 28),
            const SizedBox(height: 5),
            Text(label,
                style:
                    const TextStyle(color: Colors.white70, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

// 실제 BLE 스캐너
class _PairingScannerWidget extends StatefulWidget {
  final CentralManager central;
  final UUID serviceUUID;
  final Future<void> Function(Peripheral) onConnect;
  final Set<UUID> connectedUUIDs;

  const _PairingScannerWidget({
    required this.central,
    required this.serviceUUID,
    required this.onConnect,
    required this.connectedUUIDs,
  });

  @override
  State<_PairingScannerWidget> createState() =>
      _PairingScannerWidgetState();
}

class _PairingScannerWidgetState extends State<_PairingScannerWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _radarController;
  final List<DiscoveredEventArgs> _foundDevices = [];
  StreamSubscription? _scanSub;

  @override
  void initState() {
    super.initState();
    _radarController =
        AnimationController(vsync: this, duration: const Duration(seconds: 2))
          ..repeat();
    _startScan();
  }

  void _startScan() {
    _scanSub = widget.central.discovered.listen((event) {
      final name = event.advertisement.name ?? '';
      if (!name.contains('KREFT')) return;
      if (_foundDevices.any((d) => d.peripheral.uuid == event.peripheral.uuid)) return;
      setState(() => _foundDevices.add(event));
    });

    widget.central.startDiscovery(serviceUUIDs: [widget.serviceUUID]);
  }

  @override
  void dispose() {
    _radarController.dispose();
    _scanSub?.cancel();
    widget.central.stopDiscovery();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      height: 500,
      child: Column(
        children: [
          const Text('BLUETOOTH PAIRING',
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.5,
                  color: Colors.white)),
          const SizedBox(height: 5),
          Text('주변의 KREFT 전자찌를 탐색 중입니다...',
              style: TextStyle(
                  fontSize: 12,
                  color: Colors.white.withValues(alpha: 0.5))),
          const SizedBox(height: 30),
          // 레이더 애니메이션
          Stack(
            alignment: Alignment.center,
            children: [
              Container(
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: Colors.blueAccent.withValues(alpha: 0.3),
                          width: 1))),
              Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: Colors.blueAccent.withValues(alpha: 0.5),
                          width: 1))),
              RotationTransition(
                turns: _radarController,
                child: Container(
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: SweepGradient(colors: [
                      Colors.blueAccent.withValues(alpha: 0.0),
                      Colors.blueAccent.withValues(alpha: 0.5),
                    ], stops: const [0.5, 1.0]),
                  ),
                ),
              ),
              const Icon(Icons.bluetooth_searching,
                  color: Colors.blueAccent, size: 40),
            ],
          ),
          const SizedBox(height: 30),
          // 발견된 기기 목록
          Expanded(
            child: _foundDevices.isEmpty
                ? Center(
                    child: Text('검색 대기 중...',
                        style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.3))))
                : ListView.builder(
                    itemCount: _foundDevices.length,
                    itemBuilder: (ctx, i) {
                      final event = _foundDevices[i];
                      final name =
                          event.advertisement.name ?? 'KREFT Float';
                      final alreadyConnected = widget.connectedUUIDs
                          .contains(event.peripheral.uuid);
                      return ListTile(
                        leading: const Icon(Icons.waves,
                            color: Colors.blueAccent),
                        title: Text(name,
                            style:
                                const TextStyle(color: Colors.white)),
                        subtitle: Text(
                            '신호 강도: ${event.rssi} dBm',
                            style: TextStyle(
                                color:
                                    Colors.white.withValues(alpha: 0.4),
                                fontSize: 11)),
                        trailing: alreadyConnected
                            ? const Text('연결됨',
                                style: TextStyle(
                                    color: Colors.blueAccent,
                                    fontSize: 12))
                            : ElevatedButton(
                                onPressed: () =>
                                    widget.onConnect(event.peripheral),
                                style: ElevatedButton.styleFrom(
                                    backgroundColor:
                                        Colors.blueAccent.withValues(
                                            alpha: 0.2),
                                    shape: RoundedRectangleBorder(
                                        borderRadius:
                                            BorderRadius.circular(20))),
                                child: const Text('연결',
                                    style: TextStyle(
                                        color: Colors.blueAccent)),
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

class KreftBodyPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height, cx = w / 2;
    final paint = Paint()
      ..shader = const RadialGradient(
        center: Alignment(-0.2, -0.4),
        radius: 1.2,
        colors: [Color(0xFF444444), Color(0xFF111111), Color(0xFF000000)],
        stops: [0.0, 0.5, 1.0],
      ).createShader(Rect.fromLTWH(0, 0, w, h))
      ..style = PaintingStyle.fill;
    final path = Path()
      ..moveTo(cx, 0)
      ..cubicTo(0, 0, 0, h * 0.2, 0, h * 0.2)
      ..quadraticBezierTo(0, h * 0.5, cx - 0.5, h)
      ..lineTo(cx + 0.5, h)
      ..quadraticBezierTo(w, h * 0.5, w, h * 0.2)
      ..cubicTo(w, h * 0.2, w, 0, cx, 0)
      ..close();
    canvas.drawPath(path, paint);
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.amber.withValues(alpha: 0.2)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5,
    );
    final tp = TextPainter(
      text: const TextSpan(
          text: 'K\nR\nE\nF\nT',
          style: TextStyle(
              color: Colors.amber,
              fontSize: 8.5,
              fontWeight: FontWeight.bold,
              height: 1.1,
              letterSpacing: 1.0)),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout();
    tp.paint(canvas, Offset(cx - tp.width / 2, h * 0.15));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
