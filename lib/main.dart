// ignore_for_file: prefer_final_fields, avoid_print
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:vibration/vibration.dart';
import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';
import 'dart:io';

// BLE UUIDs
final _serviceUUID     = UUID.fromString('0000FFE0-0000-1000-8000-00805F9B34FB');
final _biteCharUUID    = UUID.fromString('0000FFE1-0000-1000-8000-00805F9B34FB');
final _commandCharUUID = UUID.fromString('0000FFE2-0000-1000-8000-00805F9B34FB');

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
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

  // 오디오
  final _audioPlayer = AudioPlayer();

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
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _initBle() async {
    // Windows는 CentralManager 미지원 — BLE 없이 UI만 표시
    if (Platform.isWindows) {
      setState(() => _bleStatus = 'Windows: BLE 스캔 미지원 (Android 앱 사용 필요)');
      return;
    }

    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();

    _bleStateSub = _central.stateChanged.listen((args) {
      if (args.state == BluetoothLowEnergyState.poweredOn) {
        setState(() => _bleStatus = '준비됨 — 페어링에서 전자찌 검색');
      } else {
        setState(() => _bleStatus = 'BLE 꺼짐');
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

    setState(() => _bleStatus = '준비됨 — 페어링에서 전자찌 검색');
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
      setState(() => _bleStatus = '${_connectedFloats.length}개 연결됨');

      // Android BLE 안정화 대기
      await Future.delayed(const Duration(milliseconds: 1000));

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
        type: GATTCharacteristicWriteType.withoutResponse,
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
          type: GATTCharacteristicWriteType.withResponse,
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
        type: GATTCharacteristicWriteType.withoutResponse,
      );
    } catch (e) {
      print('개별 명령 전송 오류: $e');
    }
  }

  void _triggerBiteAlert(int slot) {
    int index = slot - 1;
    if (index < 0 || index >= 20) return;
    setState(() => _floatBiteStates[index] = true);
    _playBiteAlert();
    Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _floatBiteStates[index] = false);
    });
  }

  Future<void> _playBiteAlert() async {
    switch (_notifyMode) {
      case 'sound':
        try {
          await _audioPlayer.stop();
          await _audioPlayer.play(AssetSource('sound/$_selectedSound.mp3'));
        } catch (_) {}
        break;
      case 'vibrate':
        final hasVibrator = await Vibration.hasVibrator() ?? false;
        if (hasVibrator) {
          Vibration.vibrate(pattern: [0, 500, 200, 500, 200, 500]);
        }
        break;
      case 'mute':
        break;
    }
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
                      onTap: () async {
                        setState(() => _selectedSound = name);
                        try {
                          await _audioPlayer.stop();
                          await _audioPlayer.play(AssetSource('sound/$name.mp3'));
                        } catch (_) {}
                        if (ctx.mounted) Navigator.pop(ctx);
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
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('SMART CONTROL',
                              style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1.5,
                                  color: Colors.white,
                                  shadows: [Shadow(color: Colors.black54, offset: Offset(1, 1), blurRadius: 3)])),
                          Row(
                            children: [
                              Icon(
                                _connectedFloats.isEmpty ? Icons.bluetooth_disabled : Icons.bluetooth_connected,
                                color: _connectedFloats.isEmpty ? Colors.white38 : Colors.blueAccent,
                                size: 11,
                              ),
                              const SizedBox(width: 3),
                              Text(_bleStatus,
                                  style: TextStyle(
                                      fontSize: 10,
                                      color: Colors.blueAccent.withValues(alpha: 0.8),
                                      fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ],
                      ),
                      Row(
                        children: [
                          SizedBox(
                            height: 28,
                            child: ElevatedButton(
                              onPressed: () {
                                setState(() {
                                  for (int i = 0; i < 20; i++) _floatPowerStates[i] = true;
                                  for (final d in _connectedFloats.values) d.isOn = true;
                                });
                                _sendCommandToAll('ON');
                              },
                              style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.blueAccent.withValues(alpha: 0.8),
                                  padding: const EdgeInsets.symmetric(horizontal: 10),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                              child: const Text('ALL ON', style: TextStyle(color: Colors.white, fontSize: 11)),
                            ),
                          ),
                          const SizedBox(width: 6),
                          SizedBox(
                            height: 28,
                            child: ElevatedButton(
                              onPressed: () {
                                setState(() {
                                  for (int i = 0; i < 20; i++) _floatPowerStates[i] = false;
                                  for (final d in _connectedFloats.values) d.isOn = false;
                                });
                                _sendCommandToAll('OFF');
                              },
                              style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.redAccent.withValues(alpha: 0.8),
                                  padding: const EdgeInsets.symmetric(horizontal: 10),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                              child: const Text('ALL OFF', style: TextStyle(color: Colors.white, fontSize: 11)),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // 찌 목록 — 화면 꽉 채우기
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final slotWidth = constraints.maxWidth / _floatCount;
                      final imgHeight = (slotWidth * 6.5)
                          .clamp(40.0, constraints.maxHeight - 56);
                      return Row(
                        children: List.generate(
                          _floatCount,
                          (i) => SizedBox(
                            width: slotWidth,
                            child: _buildKreftFloat(i + 1, imgHeight: imgHeight),
                          ),
                        ),
                      );
                    },
                  ),
                ),

                // 하단 컨트롤
                Container(
                  height: 130,
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
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          children: [
                            const Text('밝기', style: TextStyle(color: Colors.amber, fontSize: 12, fontWeight: FontWeight.bold)),
                            Expanded(
                              child: Slider(
                                value: _brightnessValue,
                                min: 0.1,
                                max: 1.0,
                                onChanged: (v) => setState(() => _brightnessValue = v),
                                onChangeEnd: (v) => _sendCommandToAll('BRIGHTNESS:${v.toStringAsFixed(2)}'),
                                activeColor: Colors.amber,
                                inactiveColor: Colors.amber.withValues(alpha: 0.3),
                              ),
                            ),
                            const Text('감도', style: TextStyle(color: Colors.cyanAccent, fontSize: 12, fontWeight: FontWeight.bold)),
                            Expanded(
                              child: Slider(
                                value: _sensitivityValue,
                                min: 0.1,
                                max: 1.0,
                                onChanged: (v) => setState(() => _sensitivityValue = v),
                                onChangeEnd: (v) => _sendCommandToAll('SENSITIVITY:${(v * 5 + 1).toStringAsFixed(1)}'),
                                activeColor: Colors.cyanAccent,
                                inactiveColor: Colors.cyanAccent.withValues(alpha: 0.3),
                              ),
                            ),
                          ],
                        ),
                      ),

                      // 하단 버튼
                      Padding(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 4),
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

  Widget _buildKreftFloat(int number, {double imgHeight = 100}) {
    final index = number - 1;
    final connected = _connectedFloats.containsKey(number);
    final isOn = _floatPowerStates[index];
    final isBite = _floatBiteStates[index];

    final badgeSize = (imgHeight * 0.2).clamp(16.0, 26.0);
    final fontSize = (badgeSize * 0.45).clamp(8.0, 12.0);
    final glowSize = (imgHeight * 0.22).clamp(14.0, 36.0);

    Color ledColor = isOn ? _currentFloatColor : Colors.grey.shade800;
    double ledOpacity = isOn ? _brightnessValue.clamp(0.3, 1.0) : 0.15;
    double glowRadius = isOn ? 18 * _brightnessValue : 0;

    if (isBite && isOn) {
      ledColor = Colors.redAccent;
      ledOpacity = 1.0;
      glowRadius = 30;
    }

    return GestureDetector(
      onLongPress: () {
        final newState = !_floatPowerStates[index];
        setState(() => _floatPowerStates[index] = newState);
        if (connected) {
          _connectedFloats[number]!.isOn = newState;
          _sendCommandToSlot(number, newState ? 'ON' : 'OFF');
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // BLE 연결 점
            Container(
              width: 5, height: 5,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: connected ? Colors.blueAccent : Colors.transparent,
              ),
            ),
            const SizedBox(height: 2),
            // 찌 이미지 + LED 글로우 오버레이
            Stack(
              alignment: Alignment.topCenter,
              clipBehavior: Clip.none,
              children: [
                // 실제 찌 이미지
                ColorFiltered(
                  colorFilter: isOn
                      ? const ColorFilter.mode(Colors.transparent, BlendMode.dst)
                      : ColorFilter.mode(Colors.grey.shade700.withValues(alpha: 0.6), BlendMode.srcATop),
                  child: Image.asset(
                    'assets/images/float_kreft.png',
                    height: imgHeight,
                    fit: BoxFit.fitHeight,
                  ),
                ),
                // LED 발광 — 찌탑 흰색 케미 위치에 글로우
                // top = -(실제크기/2) → 밝기·입질 상태와 무관하게 글로우 중심이 찌탑에 고정
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 400),
                  top: isBite
                      ? -(glowSize * 1.5 / 2)
                      : -(glowSize * _brightnessValue.clamp(0.5, 1.0) / 2),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 400),
                    width: isBite ? glowSize * 1.5 : glowSize * _brightnessValue.clamp(0.5, 1.0),
                    height: isBite ? glowSize * 1.5 : glowSize * _brightnessValue.clamp(0.5, 1.0),
                    decoration: isOn
                        ? BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(
                              colors: [
                                Colors.white.withValues(alpha: isBite ? 0.95 : 0.85 * ledOpacity),
                                ledColor.withValues(alpha: isBite ? 0.9 : 0.7 * ledOpacity),
                                ledColor.withValues(alpha: isBite ? 0.4 : 0.2 * ledOpacity),
                                ledColor.withValues(alpha: 0.0),
                              ],
                              stops: const [0.0, 0.25, 0.6, 1.0],
                            ),
                          )
                        : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // 번호 뱃지
            Container(
              width: badgeSize, height: badgeSize,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isBite ? Colors.redAccent : Colors.black.withValues(alpha: 0.6),
                border: Border.all(color: isBite ? Colors.white : Colors.white30, width: 1),
              ),
              child: Text('$number',
                  style: TextStyle(
                      color: Colors.white, fontSize: fontSize, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 3),
            // ON/OFF 표시 바
            Container(
              width: badgeSize, height: 7,
              padding: const EdgeInsets.all(1.5),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white54, width: 1.5),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Row(children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: isOn ? Colors.greenAccent : Colors.grey[800],
                      borderRadius: BorderRadius.circular(1),
                    ),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 6),
          ],
        ),
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
      if (_foundDevices.any((d) => d.peripheral.uuid == event.peripheral.uuid)) return;
      setState(() => _foundDevices.add(event));
    });

    widget.central.startDiscovery();
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
                      final name = event.advertisement.name ?? '(이름없음)';
                      final serviceUUIDs = event.advertisement.serviceUUIDs;
                      final isKreft = name.contains('KREFT') ||
                          (serviceUUIDs?.any((u) => u == widget.serviceUUID) ?? false);
                      final alreadyConnected = widget.connectedUUIDs
                          .contains(event.peripheral.uuid);
                      return ListTile(
                        leading: Icon(Icons.waves,
                            color: isKreft ? Colors.greenAccent : Colors.white38),
                        title: Text(
                            isKreft ? '★ KREFT Float' : name,
                            style: TextStyle(
                                color: isKreft ? Colors.greenAccent : Colors.white54)),
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

