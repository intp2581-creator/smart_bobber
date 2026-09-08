// ignore_for_file: prefer_final_fields, avoid_print
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:vibration/vibration.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

// BLE UUIDs
final _serviceUUID     = UUID.fromString('0000FFE0-0000-1000-8000-00805F9B34FB');
final _biteCharUUID    = UUID.fromString('0000FFE1-0000-1000-8000-00805F9B34FB');
final _commandCharUUID = UUID.fromString('0000FFE2-0000-1000-8000-00805F9B34FB');

// 색상 프리셋 — 기본색 + 입질 시 변색 규칙 (전자찌 앱과 동일하게 유지)
// 빨강→파랑, 초록→빨강, 파랑→빨강, 노랑→초록, 핑크→파랑
class ColorPreset {
  final String name;
  final int r, g, b;      // 기본색
  final int br, bg, bb;   // 입질 시 변색
  const ColorPreset(this.name, this.r, this.g, this.b, this.br, this.bg, this.bb);
  Color get base => Color.fromARGB(255, r, g, b);
  Color get bite => Color.fromARGB(255, br, bg, bb);
}

const List<ColorPreset> kColorPresets = [
  ColorPreset('레드',   255, 0,   0,     0,   200, 255), // 빨강 → 파랑
  ColorPreset('그린',   0,   255, 100,   255, 0,   0),   // 초록 → 빨강
  ColorPreset('블루',   0,   200, 255,   255, 0,   0),   // 파랑 → 빨강
  ColorPreset('옐로우', 255, 200, 0,     0,   255, 100), // 노랑 → 초록
  ColorPreset('핑크',   255, 0,   150,   0,   200, 255), // 핑크 → 파랑
];

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
      title: '크래프트',
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
  String name = '';        // 기기 고유 이름 (KREFT-XXXX)

  _FloatDevice(this.peripheral);
}

class _SmartControlHomeScreenState extends State<SmartControlHomeScreen> {
  String _notifyMode = 'sound';
  int _floatCount = 10;
  int _colorIndex = 0;                                   // 선택된 색상 프리셋
  ColorPreset get _preset => kColorPresets[_colorIndex];
  Color get _currentFloatColor => _preset.base;          // 기본 표시색
  String _selectedSound = 'sound_1';
  double _brightnessValue = 1.0;
  double _sensitivityValue = 0.5;
  bool _variColor = true;    // 입질 시 찌 변색 ON/OFF
  bool _alertPhone = true;   // 입질 시 폰 알림 ON/OFF

  // 슬롯별 전원 상태 (BLE 연결되지 않은 슬롯도 표시용)
  List<bool> _floatPowerStates = List.generate(20, (_) => true);
  List<bool> _floatBiteStates = List.generate(20, (_) => false);

  // 오디오
  final _audioPlayer = AudioPlayer();

  // BLE
  final _central = CentralManager();
  // 슬롯 번호(1~20) → 연결된 찌 디바이스
  final Map<int, _FloatDevice> _connectedFloats = {};
  // UUID 문자열 → 고정 슬롯 번호 (재연결 시 같은 슬롯 유지)
  final Map<String, int> _slotAssignments = {};
  String _bleStatus = 'BLE 초기화 중...';

  // ── 내 찌 등록 & 소유권 잠금 (도난·분실 방지) ──
  // 기기이름(KREFT-XXXX) → 소유자 키. 잠긴 찌는 이 키로만 제어 가능
  final Map<String, String> _myFloats = {};   // 이름 → key
  String _ownerKey = '';                       // 내 소유자 키(기기 공통)
  String _ownerNick = '';                      // 주인 닉네임 — 습득자가 볼 이름

  // 찌 고르기(찌함에서 꺼내는 중) 상태
  bool _picking = false;
  Timer? _pickTimer;

  // 오늘 편성 확인 흐름
  bool _startupAsked = false;          // 이번 실행에서 "몇 대 편성?" 물었는지
  bool _identifyMode = false;          // 수동으로 물에 있는 찌 찾는 중
  List<_FloatDevice> _identifyQueue = [];   // 후보 전체 (등록된 찌)
  int _identifyIndex = 0;              // 지금 깜빡이는 후보
  final List<_FloatDevice> _identified = [];  // 물에 있다고 확인된 찌
  int _identifyTarget = 0;             // 찾아야 할 개수
  // 스캔 중 확인한 UUID → 광고 이름 (연결 후 이름 참조용). 앱 재시작해도 유지
  final Map<String, String> _discoveredNames = {};

  StreamSubscription? _bleStateSub;
  StreamSubscription? _discoverySub;
  StreamSubscription? _connStateSub;
  StreamSubscription? _notifySub;

  // 앱 UI 깜빡임 (탭·드래그 중 위치 확인용) — 5색 순환(낮에도 잘 보이게)
  final Set<int> _blinkingSlots = {};
  int _blinkColorIdx = 0;
  Timer? _blinkTimer;

  // 찌 정렬 마법사 (A방식: 찌 깜빡 → 사용자가 실제 자리 번호 지정)
  bool _sortMode = false;
  List<_FloatDevice> _sortQueue = [];   // 정렬할 찌 스냅샷(깜빡 순서)
  int _sortIndex = 0;
  final Map<String, int> _sortTargets = {};  // uuid → 목표 자리

  // 음성 제어
  final _speech = SpeechToText();
  bool _speechAvailable = false;
  bool _isListening = false;
  bool _autoListen = false;   // 자동 연속 음성인식
  bool _restartScheduled = false; // 재시작 중복 방지
  String _voiceText = '';

  @override
  void initState() {
    super.initState();
    _initAll();
  }

  // BLE → 음성 순서대로 초기화 (권한 팝업 동시 충돌 방지)
  Future<void> _initAll() async {
    await _loadSettings();
    await _initBle();
    await Future.delayed(const Duration(milliseconds: 500));
    await _initSpeech();
  }

  // ── 설정 저장 / 불러오기 ──────────────────────────────────────────

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _notifyMode    = prefs.getString('notifyMode')   ?? 'sound';
      _floatCount    = prefs.getInt('floatCount')      ?? 1;
      _selectedSound = prefs.getString('selectedSound') ?? 'sound_1';
      _brightnessValue  = prefs.getDouble('brightness')  ?? 1.0;
      _sensitivityValue = prefs.getDouble('sensitivity') ?? 0.5;
      _variColor  = prefs.getBool('variColor')  ?? true;
      _alertPhone = prefs.getBool('alertPhone') ?? true;
      final savedIndex = prefs.getInt('colorIndex');
      if (savedIndex != null && savedIndex >= 0 && savedIndex < kColorPresets.length) {
        _colorIndex = savedIndex;
      }

      // 저장된 슬롯 매핑 복원
      final slotJson = prefs.getString('slotAssignments');
      if (slotJson != null) {
        try {
          final map = jsonDecode(slotJson) as Map<String, dynamic>;
          _slotAssignments.clear();
          map.forEach((k, v) => _slotAssignments[k] = v as int);
        } catch (_) {}
      }

      // 내 찌 등록 목록 & 소유자 키·닉네임 복원
      _ownerKey = prefs.getString('ownerKey') ?? '';
      _ownerNick = prefs.getString('ownerNick') ?? '';

      // 찌 이름 기억 복원 (앱 재시작 후에도 어느 찌인지 알 수 있게)
      final nameJson = prefs.getString('deviceNames');
      if (nameJson != null) {
        try {
          final map = jsonDecode(nameJson) as Map<String, dynamic>;
          _discoveredNames.clear();
          map.forEach((k, v) => _discoveredNames[k] = v as String);
        } catch (_) {}
      }
      final myJson = prefs.getString('myFloats');
      if (myJson != null) {
        try {
          final map = jsonDecode(myJson) as Map<String, dynamic>;
          _myFloats.clear();
          map.forEach((k, v) => _myFloats[k] = v as String);
        } catch (_) {}
      }
    });
  }

  // 소유자 키 생성 (기기당 1개, 12자리 영숫자)
  Future<String> _ensureOwnerKey() async {
    if (_ownerKey.isNotEmpty) return _ownerKey;
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rnd = Random.secure();
    final key = List.generate(12, (_) => chars[rnd.nextInt(chars.length)]).join();
    setState(() => _ownerKey = key);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ownerKey', key);
    return key;
  }

  Future<void> _saveMyFloats() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('myFloats', jsonEncode(_myFloats));
  }

  // 발견한 찌 이름 기억 (앱을 껐다 켜도 어느 찌인지 알 수 있게)
  Future<void> _rememberName(String uuid, String name) async {
    if (name.isEmpty || _discoveredNames[uuid] == name) return;
    _discoveredNames[uuid] = name;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('deviceNames', jsonEncode(_discoveredNames));
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('notifyMode',    _notifyMode);
    await prefs.setInt('floatCount',       _floatCount);
    await prefs.setString('selectedSound', _selectedSound);
    await prefs.setDouble('brightness',    _brightnessValue);
    await prefs.setDouble('sensitivity',   _sensitivityValue);
    await prefs.setInt('colorIndex',       _colorIndex);
    await prefs.setBool('variColor',       _variColor);
    await prefs.setBool('alertPhone',      _alertPhone);
  }

  Future<void> _saveSlotAssignments() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('slotAssignments', jsonEncode(_slotAssignments));
  }

  @override
  void dispose() {
    _bleStateSub?.cancel();
    _discoverySub?.cancel();
    _autoScanSub?.cancel();
    _connStateSub?.cancel();
    _notifySub?.cancel();
    _blinkTimer?.cancel();
    _speech.cancel();
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
      if (msg.startsWith('BITE:')) {
        // 가상 찌 번호별 입질: BITE:N
        final n = int.tryParse(msg.substring(5));
        if (n != null && n >= 1 && n <= 20) _triggerBiteAlert(n);
      } else if (msg == 'BITE') {
        // 단일 찌 레거시 신호: 연결된 슬롯으로 처리
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

    // 등록된 찌 자동 연결 시도 (한 번 페어링해두면 다음부터 자동)
    await Future.delayed(const Duration(milliseconds: 800));
    _autoReconnect();
  }

  // ── 등록된 찌 자동 연결 ──────────────────────────
  // 이전에 연결했던 찌(UUID 저장됨)를 스캔해서 자동으로 붙임
  // ⚠️ 스캔 중엔 연결기기 알림(입질)이 끊기므로, 등록 찌 다 붙으면 즉시 스캔 종료
  StreamSubscription? _autoScanSub;
  bool _autoScanning = false;
  void _autoReconnect() async {
    if (_slotAssignments.isEmpty) return;   // 등록된 찌 없으면 skip
    final known = _slotAssignments.keys.toSet();
    setState(() => _bleStatus = '등록된 찌 자동 연결 중...');

    _autoScanning = true;
    _autoScanSub?.cancel();
    _autoScanSub = _central.discovered.listen((event) async {
      final uuid = event.peripheral.uuid.toString();
      final advName = event.advertisement.name;
      if (advName != null && advName.isNotEmpty) _rememberName(uuid, advName);
      final already = _connectedFloats.values
          .any((d) => d.peripheral.uuid == event.peripheral.uuid);
      if (known.contains(uuid) && !already) {
        try {
          await _central.connect(event.peripheral);
        } catch (_) {}
        // 등록된 찌를 모두 연결했으면 즉시 스캔 종료 (알림 방해 방지)
        if (_connectedFloats.length >= known.length) _stopAutoScan();
      }
    });
    try { await _central.startDiscovery(); } catch (_) {}

    // 최대 12초 후 스캔 종료 (그동안 안 켜진 찌는 페어링에서 수동 연결)
    Future.delayed(const Duration(seconds: 12), _stopAutoScan);
  }

  void _stopAutoScan() {
    if (!_autoScanning) return;
    _autoScanning = false;
    _autoScanSub?.cancel();
    _autoScanSub = null;
    try { _central.stopDiscovery(); } catch (_) {}
    if (mounted) {
      setState(() => _bleStatus = _connectedFloats.isEmpty
          ? '준비됨 — 페어링에서 전자찌 검색'
          : '${_connectedFloats.length}개 연결됨');
      // 등록된 찌가 다 붙었으면 "오늘 몇 대 폈는지"부터 묻는다
      if (_myFloats.isNotEmpty && _connectedFloats.isNotEmpty) {
        Future.delayed(const Duration(milliseconds: 600), _askTodayCount);
      }
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
      final uuidStr = peripheral.uuid.toString();

      // 기존에 배정된 슬롯이 있으면 재사용, 없으면 빈 슬롯 찾기
      int? slot = _slotAssignments[uuidStr];
      if (slot == null || _connectedFloats.containsKey(slot)) {
        slot = 1;
        while (_connectedFloats.containsKey(slot!) ||
            _slotAssignments.values.contains(slot)) {
          slot++;
          if (slot > 20) return;
        }
        _slotAssignments[uuidStr] = slot;
        _saveSlotAssignments();
      }

      final device = _FloatDevice(peripheral);
      device.name = _discoveredNames[uuidStr] ?? '';
      _connectedFloats[slot] = device;
      setState(() => _bleStatus = '${_connectedFloats.length}개 연결됨');

      // Android BLE 안정화 대기
      await Future.delayed(const Duration(milliseconds: 1000));

      // GATT 탐색 (진단용 플래그 수집) — 실패 시 2회까지 재시도
      bool svcFound = false;
      bool notifyOk = false;
      bool cmdBound = false;
      for (int attempt = 0; attempt < 3; attempt++) {
        final services = await _central.discoverGATT(peripheral);
        for (final svc in services) {
          if (svc.uuid == _serviceUUID) {
            svcFound = true;
            for (final chr in svc.characteristics) {
              if (chr.uuid == _biteCharUUID) {
                await _central.setCharacteristicNotifyState(
                    peripheral, chr, state: true);
                notifyOk = true;
              }
              if (chr.uuid == _commandCharUUID) {
                device.commandChar = chr;
                cmdBound = true;
              }
            }
          }
        }
        if (svcFound && notifyOk && cmdBound) break;
        await Future.delayed(const Duration(milliseconds: 700));
      }

      // 진단: 어디서 끊겼는지 화면에 표시
      if (!svcFound) {
        setState(() => _bleStatus = '⚠ GATT 서비스 미발견 — 찌 재시작 필요');
      } else if (!notifyOk || !cmdBound) {
        setState(() => _bleStatus =
            '⚠ 특성 누락 notify=$notifyOk cmd=$cmdBound');
      }

      // 현재 설정값 전송
      await _sendSettings(device);

      if (svcFound && notifyOk && cmdBound) {
        setState(() => _bleStatus = '${_connectedFloats.length}개 연결됨 ✓GATT');
      }
    } catch (e) {
      // 예외 메시지가 길어서 화면 안 깨지게 짧게만 표시
      setState(() => _bleStatus = '연결 재시도 중...');
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
      // _slotAssignments 는 유지 (재연결 시 같은 슬롯 복원)
    }
  }


  Future<void> _sendSettings(_FloatDevice device) async {
    if (device.commandChar == null) return;
    final chr = device.commandChar!;
    final p = device.peripheral;

    final cmds = <String>[
      // 잠긴 찌는 인증을 먼저 통과해야 명령을 받음.
      // 소유자 키는 폰당 하나뿐이므로 찌 이름을 몰라도(앱 재시작 등) 항상 보낸다.
      // 잠기지 않은 찌는 AUTH를 받아도 그대로 통과하므로 안전.
      if (_ownerKey.isNotEmpty) 'AUTH:$_ownerKey',
      device.isOn ? 'ON' : 'OFF',
      'COLOR:${_preset.r},${_preset.g},${_preset.b}',
      'BRIGHTNESS:${_brightnessValue.toStringAsFixed(2)}',
      'SENSITIVITY:${(_sensitivityValue * 5 + 1).toStringAsFixed(1)}',
      'VARI:${_variColor ? 1 : 0}',
      'ALERT:${_alertPhone ? 1 : 0}',
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

  // 탭: 해당 찌 LED 깜빡임 → 물 위에서 위치 확인
  void _blinkFloat(int slot) {
    _sendCommandToSlot(slot, 'BLINK');
  }

  // ── 소유권 잠금 (도난·분실 방지) ────────────────────
  // 연결된 찌를 내 것으로 등록하고 잠금 → 다른 사람 앱에서 제어 불가
  // 찌를 식별하는 키 — 광고 이름이 없으면 UUID로 대신한다
  String _idOf(_FloatDevice d) =>
      d.name.isNotEmpty ? d.name : d.peripheral.uuid.toString();

  Future<void> _lockFloat(_FloatDevice device) async {
    final key = await _ensureOwnerKey();
    // LOCK:키:닉네임 — 닉네임은 습득자가 주인을 알아볼 수 있게 찌 광고에 노출됨
    final nick = _ownerNick.isEmpty ? '' : ':$_ownerNick';
    await _sendCommandToDevice(device, 'LOCK:$key$nick');
    setState(() => _myFloats[_idOf(device)] = key);
    await _saveMyFloats();
  }

  // 닉네임 입력 (최초 1회만 — 이후 모든 찌에 같은 닉네임 사용)
  Future<bool> _ensureOwnerNick() async {
    if (_ownerNick.isNotEmpty) return true;
    final ctrl = TextEditingController();
    final nick = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        backgroundColor: const Color(0xFF1A1D23),
        title: const Text('닉네임 설정',
            style: TextStyle(color: Colors.white, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
                '찌를 잃어버렸을 때 주운 사람이 볼 이름입니다.\n한 번만 입력하면 모든 찌에 적용됩니다.',
                style: TextStyle(color: Colors.white70, fontSize: 12)),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              maxLength: 12,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                hintText: '예: 손맛왕',
                hintStyle: TextStyle(color: Colors.white24),
                counterStyle: TextStyle(color: Colors.white24),
                enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: Colors.white24)),
                focusedBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: Colors.blueAccent)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d),
              child: const Text('취소', style: TextStyle(color: Colors.white54))),
          TextButton(
              onPressed: () => Navigator.pop(d, ctrl.text.trim()),
              child: const Text('확인',
                  style: TextStyle(color: Colors.blueAccent))),
        ],
      ),
    );
    if (nick == null || nick.isEmpty) return false;
    setState(() => _ownerNick = nick);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ownerNick', nick);
    return true;
  }

  // 잠금 해제 (중고 양도 시) → 새 주인이 다시 등록 가능
  Future<void> _unlockFloat(_FloatDevice device) async {
    final key = _myFloats[_idOf(device)];
    if (key == null) return;
    await _sendCommandToDevice(device, 'UNLOCK:$key');
    setState(() => _myFloats.remove(_idOf(device)));
    await _saveMyFloats();
  }

  Future<void> _sendCommandToDevice(_FloatDevice device, String cmd) async {
    if (device.commandChar == null) return;
    try {
      await _central.writeCharacteristic(
        device.peripheral,
        device.commandChar!,
        value: Uint8List.fromList(utf8.encode(cmd)),
        type: GATTCharacteristicWriteType.withoutResponse,
      );
    } catch (_) {}
  }

  // 연결된 찌 전체 잠금 / 해제
  Future<void> _lockAll() async {
    if (!await _ensureOwnerNick()) return;   // 닉네임 최초 1회 입력
    int done = 0;
    for (final d in _connectedFloats.values) {
      if (!_myFloats.containsKey(_idOf(d))) {
        await _lockFloat(d);
        done++;
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }
    // 등록된 찌 개수에 맞춰 화면도 정리 (등록 안내 화면이 닫힌다)
    setState(() {
      _floatCount = _connectedFloats.isEmpty ? 1 : _connectedFloats.length;
      _bleStatus = '내 찌 ${_myFloats.length}개 등록·잠금됨';
    });
    await _saveSettings();
    if (done > 0 && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('찌 ${_myFloats.length}개 등록 완료!'),
        backgroundColor: Colors.green,
        duration: const Duration(seconds: 2),
      ));
    }
  }

  Future<void> _unlockAll() async {
    for (final d in _connectedFloats.values) {
      if (_myFloats.containsKey(_idOf(d))) {
        await _unlockFloat(d);
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }
    setState(() => _bleStatus = '잠금 해제됨 (양도 가능)');
  }

  // 앱 UI 깜빡임 타이머 (150ms 주기, 5색 순환 — 물리 찌와 동기화)
  void _startBlinkTimer() {
    _blinkTimer ??= Timer.periodic(const Duration(milliseconds: 150), (_) {
      if (mounted) setState(() => _blinkColorIdx = (_blinkColorIdx + 1) % 5);
    });
  }

  void _stopBlinkIfDone() {
    if (_blinkingSlots.isEmpty) {
      _blinkTimer?.cancel();
      _blinkTimer = null;
      if (mounted) setState(() => _blinkColorIdx = 0);
    }
  }

  // ── 찌 정렬 마법사 (A방식) ──────────────────────────
  // 시작: 연결된 찌를 하나씩 깜빡 → 사용자가 실제 물 위 자리 번호를 말/탭 → 그 자리로 이동
  void _startSortWizard() async {
    if (_connectedFloats.isEmpty) {
      setState(() => _bleStatus = '⚠ 연결된 찌가 없어요 (먼저 페어링)');
      return;
    }
    // 정렬하려면 찌가 보여야 하므로 자동으로 전부 켠다 (대편성 중엔 꺼져 있음)
    await _sendCommandToAll('ON');
    setState(() {
      for (int i = 0; i < _floatPowerStates.length; i++) {
        _floatPowerStates[i] = true;
      }
    });
    for (final d in _connectedFloats.values) {
      d.isOn = true;
    }

    final entries = _connectedFloats.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    _sortQueue = entries.map((e) => e.value).toList();
    _sortTargets.clear();
    _sortIndex = 0;
    setState(() => _sortMode = true);
    _sortBlinkCurrent();
  }

  // 현재 순서의 찌를 깜빡 (물에서 어느 건지 보여줌)
  void _sortBlinkCurrent() {
    if (_sortIndex >= _sortQueue.length) return;
    final slot = _slotOf(_sortQueue[_sortIndex].peripheral);
    if (slot != null) {
      _blinkFloat(slot);
      setState(() => _blinkingSlots.add(slot));
      _startBlinkTimer();
    }
  }

  // 사용자가 목표 자리 번호 지정 (음성/탭)
  void _sortAssign(int pos) {
    if (!_sortMode || _sortIndex >= _sortQueue.length) return;
    if (pos < 1 || pos > 20) return;
    _sortTargets[_sortQueue[_sortIndex].peripheral.uuid.toString()] = pos;
    _blinkingSlots.clear();
    _stopBlinkIfDone();
    _sortIndex++;
    if (_sortIndex >= _sortQueue.length) {
      _applySortResult();
    } else {
      setState(() {});
      _sortBlinkCurrent();
    }
  }

  // 정렬 결과 적용 — 각 찌를 목표 자리로 재배치
  void _applySortResult() {
    final newFloats = <int, _FloatDevice>{};
    final newPower = List<bool>.from(_floatPowerStates);
    for (final device in _sortQueue) {
      final uuid = device.peripheral.uuid.toString();
      final target = _sortTargets[uuid];
      if (target != null && target >= 1 && target <= 20) {
        newFloats[target] = device;
        _slotAssignments[uuid] = target;
        newPower[target - 1] = device.isOn;
      }
    }
    setState(() {
      _connectedFloats
        ..clear()
        ..addAll(newFloats);
      _floatPowerStates = newPower;
      _sortMode = false;
      _blinkingSlots.clear();
      _bleStatus = '✓ 정렬 완료 (${newFloats.length}개)';
    });
    _blinkTimer?.cancel();
    _blinkTimer = null;
    _saveSlotAssignments();

    // 정렬이 끝나면 불을 끈다 (낮낚시 중 배터리 절약 — 밤엔 ALL ON으로 켜기)
    _sendCommandToAll('OFF');
    for (final d in _connectedFloats.values) {
      d.isOn = false;
    }
    setState(() {
      for (int i = 0; i < _floatPowerStates.length; i++) {
        _floatPowerStates[i] = false;
      }
      _bleStatus = '✓ 정렬 완료 (${newFloats.length}대) — 어두워지면 ALL ON';
    });
  }

  void _cancelSort() {
    _blinkingSlots.clear();
    _blinkTimer?.cancel();
    _blinkTimer = null;
    setState(() {
      _sortMode = false;
      _blinkColorIdx = 0;
      _bleStatus = '정렬 취소됨';
    });
  }

  // 탭 시: autoStop=true → 2400ms 후 자동 종료 (8회 깜빡)
  // 드래그 시: autoStop=false → 드롭 완료 시 _removeBlink 호출로 종료
  void _addBlink(int slot, {bool autoStop = true}) {
    setState(() => _blinkingSlots.add(slot));
    _startBlinkTimer();
    if (autoStop) {
      Future.delayed(const Duration(milliseconds: 2400), () {
        if (mounted) {
          setState(() => _blinkingSlots.remove(slot));
          _stopBlinkIfDone();
        }
      });
    }
  }

  void _removeBlink(int slot) {
    setState(() => _blinkingSlots.remove(slot));
    _stopBlinkIfDone();
  }

  // ── 음성 제어 ─────────────────────────────────────────────
  Future<void> _initSpeech() async {
    if (!Platform.isWindows) {
      await Permission.microphone.request();
    }
    _speechAvailable = await _speech.initialize(
      onStatus: (status) {
        if (mounted && (status == 'done' || status == 'notListening')) {
          setState(() => _isListening = false);
          _scheduleAutoRestart(); // 타임아웃/무음 종료 시 재시작
        }
      },
      onError: (_) {
        if (mounted) setState(() { _isListening = false; });
        _scheduleAutoRestart();
      },
    );
    if (mounted) setState(() {});
  }

  Future<void> _toggleListening() async {
    if (_isListening) {
      await _speech.stop();
      if (mounted) setState(() { _isListening = false; _voiceText = ''; _autoListen = false; });
      return;
    }
    if (!_speechAvailable) return;
    await _startListening();
  }

  // 자동 재시작 — 중복 방지 플래그로 onStatus/onResult 동시 트리거 충돌 해결
  void _scheduleAutoRestart() {
    if (!_autoListen || _restartScheduled) return;
    _restartScheduled = true;
    Future.delayed(const Duration(milliseconds: 1500), () {
      _restartScheduled = false;
      if (mounted && _autoListen && !_isListening) {
        setState(() => _voiceText = '대기 중...');
        _startListening();
      }
    });
  }

  Future<void> _startListening() async {
    if (!_speechAvailable || _isListening) return;
    setState(() { _isListening = true; _voiceText = '듣는 중...'; });
    await _speech.listen(
      onResult: (result) {
        if (!mounted) return;
        setState(() => _voiceText = result.recognizedWords);
        if (result.finalResult) {
          setState(() => _isListening = false);
          final words = result.recognizedWords.trim();
          if (words.isNotEmpty) {
            _parseVoiceCommand(words);
            // 인식된 명령어를 1.5초간 표시 후 재시작
            setState(() => _voiceText = '✓ $words');
          }
          _scheduleAutoRestart();
          // 자동 모드 아닐 때는 2초 후 텍스트 제거
          if (!_autoListen) {
            Future.delayed(const Duration(seconds: 2), () {
              if (mounted) setState(() => _voiceText = '');
            });
          }
        }
      },
      // dictation 모드 = 문장 중간 멈춤 견딤(말하다 끊기는 문제 해결)
      listenOptions: SpeechListenOptions(
        localeId: 'ko_KR',
        listenMode: ListenMode.dictation,
        partialResults: true,
        cancelOnError: false,
        listenFor: const Duration(seconds: 30),
        pauseFor: const Duration(seconds: 4),  // 말 끝나고 4초 침묵해야 종료
      ),
    );
  }

  // 음성에서 숫자 하나 추출 (아라비아 + 한글, 번 없어도) — 정렬 모드용
  int? _extractNumber(String s) {
    final m = RegExp(r'(\d+)').firstMatch(s);
    if (m != null) {
      final n = int.tryParse(m.group(1)!);
      if (n != null && n >= 1 && n <= 20) return n;
    }
    const sino   = ['일', '이', '삼', '사', '오', '육', '칠', '팔', '구', '십'];
    const native = ['한', '두', '세', '네', '다섯', '여섯', '일곱', '여덟', '아홉', '열'];
    for (int i = 0; i < 10; i++) {
      if (s.contains(sino[i]) || s.contains(native[i])) return i + 1;
    }
    return null;
  }

  void _parseVoiceCommand(String text) {
    // 띄어쓰기 제거 + 소문자화 → 매칭 너그럽게 ("삼 번"·"3 번"·"3번" 다 인식)
    final t = text.toLowerCase().replaceAll(' ', '');

    // ── 정렬 마법사 진행 중: 숫자=자리지정, 취소=종료 ──
    if (_sortMode) {
      if (t.contains('취소') || t.contains('그만') || t.contains('중지') || t.contains('스톱')) {
        _cancelSort();
        return;
      }
      final p = _extractNumber(t);
      if (p != null) _sortAssign(p);
      return;   // 정렬 중엔 다른 명령 무시
    }

    // ── 정렬 시작 ("찌 정렬", "순서 맞추자", "정렬하자") ──
    if (t.contains('정렬') || t.contains('순서맞') || t.contains('순서정') || t.contains('순서바')) {
      _startSortWizard();
      return;
    }

    // 색상 변경 헬퍼 (프리셋 인덱스 선택)
    void setColorIndex(int i) {
      final p = kColorPresets[i];
      setState(() => _colorIndex = i);
      _sendCommandToAll('COLOR:${p.r},${p.g},${p.b}');
      _saveSettings();
    }

    // ── 전체 ON / OFF ──────────────────────────
    if (t.contains('전체') || t.contains('모두') || t.contains('전부')) {
      if (t.contains('켜') || t.contains('온')) {
        setState(() {
          for (int i = 0; i < 20; i++) { _floatPowerStates[i] = true; }
          for (final d in _connectedFloats.values) { d.isOn = true; }
        });
        _sendCommandToAll('ON');
      } else if (t.contains('꺼') || t.contains('오프')) {
        setState(() {
          for (int i = 0; i < 20; i++) { _floatPowerStates[i] = false; }
          for (final d in _connectedFloats.values) { d.isOn = false; }
        });
        _sendCommandToAll('OFF');
      }
      return;
    }

    // ── 슬롯 번호 추출 헬퍼 (아라비아 + 한글 사이노/고유어 다 인식) ──
    int? parseSlot(String src) {
      // 1) 아라비아 숫자 + 번
      final m = RegExp(r'(\d+)번').firstMatch(src);
      if (m != null) {
        final n = int.tryParse(m.group(1)!);
        if (n != null && n >= 1 && n <= 20) return n;
      }
      // 2) 한글 숫자 — 사이노(일이삼) + 고유어(한두세네)
      const sino   = ['일', '이', '삼', '사', '오', '육', '칠', '팔', '구', '십'];
      const native = ['한', '두', '세', '네', '다섯', '여섯', '일곱', '여덟', '아홉', '열'];
      for (int i = 0; i < 10; i++) {
        if (src.contains('${sino[i]}번') || src.contains('${native[i]}번')) return i + 1;
      }
      return null;
    }

    // ── 여러 슬롯 번호 모두 추출 ("2번 4번 6번") ──
    List<int> parseAllSlots(String src) {
      final set = <int>{};
      for (final mm in RegExp(r'(\d+)번').allMatches(src)) {
        final n = int.tryParse(mm.group(1)!);
        if (n != null && n >= 1 && n <= 20) set.add(n);
      }
      const sino   = ['일', '이', '삼', '사', '오', '육', '칠', '팔', '구', '십'];
      const native = ['한', '두', '세', '네', '다섯', '여섯', '일곱', '여덟', '아홉', '열'];
      for (int i = 0; i < 10; i++) {
        if (src.contains('${sino[i]}번') || src.contains('${native[i]}번')) set.add(i + 1);
      }
      return set.toList()..sort();
    }

    // ── 여러 슬롯에 ON/OFF 적용 ──
    void applyPower(List<int> slots, bool on) {
      setState(() {
        for (final s in slots) {
          if (s >= 1 && s <= 20) _floatPowerStates[s - 1] = on;
          final d = _connectedFloats[s];
          if (d != null) d.isOn = on;
        }
      });
      for (final s in slots) {
        if (_connectedFloats.containsKey(s)) {
          _sendCommandToSlot(s, on ? 'ON' : 'OFF');
        }
      }
    }

    // ── 이동/스왑 ("3번을 1번으로 이동해줘") ──
    if (t.contains('이동') || t.contains('옮') || t.contains('바꿔') || t.contains('바꾸')) {
      final allMatches = RegExp(r'(\d+)\s*번').allMatches(t).toList();
      if (allMatches.length >= 2) {
        final s1 = int.tryParse(allMatches[0].group(1)!);
        final s2 = int.tryParse(allMatches[1].group(1)!);
        if (s1 != null && s2 != null && s1 >= 1 && s1 <= 20 && s2 >= 1 && s2 <= 20) {
          _swapSlots(s1, s2);
          return;
        }
      }
    }

    // ── 켜/꺼 의도 판별 (여러 표현 커버) ──
    final wantsOn  = t.contains('켜') || t.contains('온') || t.contains('점등');
    final wantsOff = t.contains('꺼') || t.contains('오프') || t.contains('소등');

    // ── 짝수 / 홀수 ("짝수 꺼줘", "홀수 켜") ──
    if ((t.contains('짝수') || t.contains('홀수')) && (wantsOn || wantsOff)) {
      final even = t.contains('짝수');
      final slots = <int>[];
      for (int i = 1; i <= _floatCount; i++) {
        if (even ? (i % 2 == 0) : (i % 2 == 1)) slots.add(i);
      }
      applyPower(slots, !wantsOff);   // 꺼 우선
      return;
    }

    // ── 다중 슬롯 ("2번 4번 6번 8번 꺼줘") ──
    if (wantsOn || wantsOff) {
      final slots = parseAllSlots(t);
      if (slots.length >= 2) {
        applyPower(slots, !wantsOff);
        return;
      }
    }

    // ── N번만 켜 ("3번만 켜") ─────────────────
    if (t.contains('만') && (t.contains('켜') || t.contains('온'))) {
      final slot = parseSlot(t);
      if (slot != null && slot >= 1 && slot <= 20) {
        setState(() {
          for (int i = 0; i < 20; i++) {
            _floatPowerStates[i] = (i + 1 == slot);
          }
          for (final entry in _connectedFloats.entries) {
            entry.value.isOn = (entry.key == slot);
          }
        });
        for (final entry in _connectedFloats.entries) {
          _sendCommandToSlot(entry.key, entry.key == slot ? 'ON' : 'OFF');
        }
        return;
      }
    }

    // ── 단일 슬롯 명령 ─────────────────────────
    final slot = parseSlot(t);
    if (slot != null && slot >= 1 && slot <= 20) {
      if (t.contains('깜빡') || t.contains('위치') || t.contains('어디')) {
        _blinkFloat(slot);
        _addBlink(slot);
      } else if (t.contains('켜') || t.contains('온')) {
        setState(() => _floatPowerStates[slot - 1] = true);
        if (_connectedFloats.containsKey(slot)) {
          _connectedFloats[slot]!.isOn = true;
          _sendCommandToSlot(slot, 'ON');
        }
      } else if (t.contains('꺼') || t.contains('오프')) {
        setState(() => _floatPowerStates[slot - 1] = false);
        if (_connectedFloats.containsKey(slot)) {
          _connectedFloats[slot]!.isOn = false;
          _sendCommandToSlot(slot, 'OFF');
        }
      }
      return;
    }

    // ── 색상 ─────────────────────────────────── (프리셋: 0레드 1그린 2블루 3옐로우 4핑크)
    if (t.contains('빨')) { setColorIndex(0); return; }
    if (t.contains('파') || t.contains('블루')) { setColorIndex(2); return; }
    if (t.contains('초록') || t.contains('그린')) { setColorIndex(1); return; }
    if (t.contains('노랑') || t.contains('노란') || t.contains('옐로')) { setColorIndex(3); return; }
    if (t.contains('핑크') || t.contains('분홍')) { setColorIndex(4); return; }

    // ── 밝기 ───────────────────────────────────
    if (t.contains('밝기') || t.contains('밝게') || t.contains('어둡')) {
      double v;
      if (t.contains('최대') || t.contains('100')) {
        v = 1.0;
      } else if (t.contains('최소')) {
        v = 0.1;
      } else if (t.contains('올') || t.contains('높') || t.contains('업') || t.contains('밝게')) {
        v = (_brightnessValue + 0.2).clamp(0.1, 1.0);
      } else if (t.contains('내') || t.contains('낮') || t.contains('다운') || t.contains('줄') || t.contains('어둡')) {
        v = (_brightnessValue - 0.2).clamp(0.1, 1.0);
      } else {
        return;
      }
      setState(() => _brightnessValue = v);
      _sendCommandToAll('BRIGHTNESS:${v.toStringAsFixed(2)}');
      _saveSettings();
      return;
    }

    // ── 감도 ───────────────────────────────────
    if (t.contains('감도')) {
      double v;
      if (t.contains('최대')) {
        v = 1.0;
      } else if (t.contains('최소')) {
        v = 0.1;
      } else if (t.contains('올') || t.contains('높') || t.contains('업') || t.contains('세게') || t.contains('강')) {
        v = (_sensitivityValue + 0.2).clamp(0.1, 1.0);
      } else if (t.contains('내') || t.contains('낮') || t.contains('다운') || t.contains('줄') || t.contains('약')) {
        v = (_sensitivityValue - 0.2).clamp(0.1, 1.0);
      } else {
        return;
      }
      setState(() => _sensitivityValue = v);
      _sendCommandToAll('SENSITIVITY:${(v * 5 + 1).toStringAsFixed(1)}');
      _saveSettings();
    }
  }

  // 드래그 완료: 두 슬롯의 찌 교환
  void _swapSlots(int slot1, int slot2) {
    if (slot1 == slot2) return;
    setState(() {
      final dev1 = _connectedFloats[slot1];
      final dev2 = _connectedFloats[slot2];
      _connectedFloats.remove(slot1);
      _connectedFloats.remove(slot2);
      if (dev2 != null) { _connectedFloats[slot1] = dev2; }
      if (dev1 != null) { _connectedFloats[slot2] = dev1; }

      final ps = _floatPowerStates[slot1 - 1];
      _floatPowerStates[slot1 - 1] = _floatPowerStates[slot2 - 1];
      _floatPowerStates[slot2 - 1] = ps;

      final bs = _floatBiteStates[slot1 - 1];
      _floatBiteStates[slot1 - 1] = _floatBiteStates[slot2 - 1];
      _floatBiteStates[slot2 - 1] = bs;

      // UUID → 슬롯 매핑도 함께 업데이트 (재연결 시 같은 슬롯 복원)
      if (dev1 != null) {
        _slotAssignments[dev1.peripheral.uuid.toString()] = slot2;
      }
      if (dev2 != null) {
        _slotAssignments[dev2.peripheral.uuid.toString()] = slot1;
      }
    });
    _saveSlotAssignments();
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
        final hasVibrator = await Vibration.hasVibrator() == true;
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
    _saveSettings();
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

  // 오늘 쓸 찌 고르기 — 고른 개수만큼 찌함에서 번호순으로 반짝이게 한다.
  // 반짝이는 것만 꺼내 던지고 [선택 완료]를 누르면 불이 꺼지고 그 개수만 화면에 남는다.
  void _showCountSelector() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black.withValues(alpha: 0.92),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => Container(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('오늘 몇 대 쓰세요?',
                  style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Colors.white)),
              const SizedBox(height: 6),
              Text(
                  _connectedFloats.isEmpty
                      ? '숫자를 누르면 찌함에서 그만큼 반짝입니다'
                      : '현재 ${_connectedFloats.length}대 사용 중 — 늘리면 추가, 줄이면 걷기',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13, color: Colors.white54)),
              const SizedBox(height: 18),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                // 등록해 둔 찌 개수까지만 (없으면 20까지)
                itemCount: _myFloats.isNotEmpty
                    ? _myFloats.length
                    : (_connectedFloats.isNotEmpty
                        ? _connectedFloats.length
                        : 20),
                gridDelegate:
                    const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 5,
                        mainAxisSpacing: 10,
                        crossAxisSpacing: 10,
                        childAspectRatio: 1.4),
                itemBuilder: (ctx, i) {
                  final n = i + 1;
                  final sel = _floatCount == n;
                  return InkWell(
                    onTap: () async {
                      // 기준은 화면 칸 수가 아니라 실제 물에 나가 있는(연결된) 찌 수
                      final before = _connectedFloats.length;
                      Navigator.pop(ctx);
                      if (n > before) {
                        // 대를 더 펴는 경우 — 늘어난 번호만 반짝
                        setState(() => _floatCount = n);
                        _saveSettings();
                        await _blinkPickList(n, from: before + 1);
                      } else if (n < before) {
                        // 대를 걷는 경우 — 어느 찌를 뺄지 직접 고르게 한다
                        await _showRemovePicker(before, before - n);
                      } else {
                        setState(() => _floatCount = n);
                        _saveSettings();
                        await _blinkPickList(n);
                      }
                    },
                    child: Container(
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: sel
                            ? Colors.blueAccent
                            : Colors.white.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                            color: sel ? Colors.blueAccent : Colors.transparent,
                            width: 2),
                      ),
                      child: Text('$n',
                          style: TextStyle(
                              color: sel ? Colors.white : Colors.white70,
                              fontWeight: FontWeight.bold,
                              fontSize: 22)),
                    ),
                  );
                },
              ),
              const SizedBox(height: 14),
              const Text('꺼낸 뒤 아래 [선택완료]를 누르세요',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: Colors.white38)),
            ],
          ),
        ),
      ),
    );
  }

  // 1~count번 찌를 계속 반짝이게 (찌함에서 골라 꺼내는 동안)
  // from~count번 찌를 계속 반짝이게 (찌함에서 골라 꺼내는 동안)
  // 대를 더 펼 때는 from을 지정해 새로 추가되는 번호만 반짝이게 한다.
  Future<void> _blinkPickList(int count, {int from = 1}) async {
    _pickTimer?.cancel();
    final n = count - from + 1;
    setState(() {
      _picking = true;
      _bleStatus = from > 1
          ? '✨ 추가된 $n개를 꺼내세요 — 다 꺼내면 [선택완료]'
          : '✨ 반짝이는 $n개를 꺼내세요 — 다 꺼내면 [선택완료]';
    });
    Future<void> pulse() async {
      for (int slot = from; slot <= count; slot++) {
        await _sendCommandToSlot(slot, 'BLINK');
      }
    }
    await pulse();
    // BLINK는 약 3초 후 멈추므로 주기적으로 다시 보내 계속 반짝이게 한다
    _pickTimer = Timer.periodic(const Duration(seconds: 3), (_) => pulse());
  }

  // ── 낚시 시작 흐름 ─────────────────────────────────────────
  // 대부분 대를 먼저 펴고 앱을 켜므로, 앱은 "몇 대 폈는지"부터 묻는다.
  Future<void> _askTodayCount() async {
    if (_startupAsked || _connectedFloats.isEmpty) return;
    _startupAsked = true;
    final total = _connectedFloats.length;

    final n = await showDialog<int>(
      context: context,
      barrierDismissible: false,
      builder: (d) => AlertDialog(
        backgroundColor: const Color(0xFF1A1D23),
        title: const Text('오늘은 몇 대 편성하셨나요?',
            style: TextStyle(color: Colors.white, fontSize: 18)),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('등록된 찌 $total개 중에서 고르세요',
                  style: const TextStyle(color: Colors.white54, fontSize: 13)),
              const SizedBox(height: 14),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: total,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 5,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 1.4),
                itemBuilder: (c, i) => InkWell(
                  onTap: () => Navigator.pop(d, i + 1),
                  child: Container(
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text('${i + 1}',
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 20)),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d),
              child: const Text('나중에',
                  style: TextStyle(color: Colors.white54))),
        ],
      ),
    );
    if (n == null || n <= 0) return;
    await _guessFloatsInWater(n);
  }

  // 신호가 약한 순 = 멀리 있는 = 물에 던져진 찌로 추정해 n개를 켜본다
  Future<void> _guessFloatsInWater(int n) async {
    setState(() => _bleStatus = '물에 있는 찌 확인 중...');
    final list = _connectedFloats.values.toList();
    final rssi = <_FloatDevice, int>{};
    for (final d in list) {
      try {
        rssi[d] = await _central.readRSSI(d.peripheral);
      } catch (_) {
        rssi[d] = 0;     // 못 읽으면 중간값 취급
      }
    }
    // 약한 순(작은 값)으로 정렬 → 앞에서 n개가 물에 있을 가능성이 높다
    list.sort((a, b) => (rssi[a] ?? 0).compareTo(rssi[b] ?? 0));
    final guess = list.take(n).toList();

    // 후보만 켜서 눈으로 확인시킨다
    for (final d in _connectedFloats.values) {
      await _sendCommandToDevice(d, guess.contains(d) ? 'ON' : 'OFF');
      d.isOn = guess.contains(d);
    }
    setState(() {
      for (final e in _connectedFloats.entries) {
        _floatPowerStates[e.key - 1] = guess.contains(e.value);
      }
    });

    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (d) => AlertDialog(
        backgroundColor: const Color(0xFF1A1D23),
        title: const Text('이 찌가 맞나요?',
            style: TextStyle(color: Colors.white, fontSize: 18)),
        content: Text(
            '물에 있는 찌 $n개에 불을 켰습니다.\n켜진 찌가 오늘 쓰실 찌가 맞나요?',
            style: const TextStyle(color: Colors.white70, fontSize: 14)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d, false),
              child: const Text('아니요',
                  style: TextStyle(color: Colors.redAccent, fontSize: 16))),
          TextButton(
              onPressed: () => Navigator.pop(d, true),
              child: const Text('확인',
                  style: TextStyle(
                      color: Colors.greenAccent,
                      fontSize: 16,
                      fontWeight: FontWeight.bold))),
        ],
      ),
    );

    if (ok == true) {
      await _keepOnly(guess);      // 맞으면 그 8개만 남기고
      _startSortWizard();          // 바로 정렬로
    } else {
      _startIdentify(n);           // 아니면 하나씩 찾기
    }
  }

  // 고른 찌만 남기고 나머지는 목록에서 제외(불 끄기)
  Future<void> _keepOnly(List<_FloatDevice> keep) async {
    for (final d in _connectedFloats.values) {
      if (!keep.contains(d)) await _sendCommandToDevice(d, 'OFF');
    }
    setState(() {
      _connectedFloats.clear();
      for (int i = 0; i < keep.length; i++) {
        final slot = i + 1;
        _connectedFloats[slot] = keep[i];
        _slotAssignments[keep[i].peripheral.uuid.toString()] = slot;
        _floatPowerStates[i] = true;
      }
      for (int i = keep.length; i < _floatPowerStates.length; i++) {
        _floatPowerStates[i] = false;
        _floatBiteStates[i] = false;
      }
      _floatCount = keep.length;
    });
    _saveSlotAssignments();
    _saveSettings();
  }

  // 수동 확인 — 등록된 찌를 하나씩 5색으로 깜빡여 물에 있는 것을 찾는다
  void _startIdentify(int target) {
    _identifyQueue = _connectedFloats.values.toList();
    _identified.clear();
    _identifyIndex = 0;
    _identifyTarget = target;
    setState(() => _identifyMode = true);
    _sendCommandToAll('OFF');
    _identifyBlinkCurrent();
  }

  void _identifyBlinkCurrent() {
    if (_identifyIndex >= _identifyQueue.length) return;
    final dev = _identifyQueue[_identifyIndex];
    final slot = _slotOf(dev.peripheral);
    if (slot != null) {
      _blinkFloat(slot);
      setState(() => _blinkingSlots
        ..clear()
        ..add(slot));
      _startBlinkTimer();
    }
  }

  // 물에 있다 → 사용 목록에 넣기 / 없다(찌함) → 건너뛰기
  void _identifyAnswer(bool inWater) {
    if (!_identifyMode) return;
    if (inWater && _identifyIndex < _identifyQueue.length) {
      _identified.add(_identifyQueue[_identifyIndex]);
    }
    _identifyIndex++;
    _blinkingSlots.clear();
    if (_identified.length >= _identifyTarget ||
        _identifyIndex >= _identifyQueue.length) {
      _finishIdentify();
    } else {
      setState(() {});
      _identifyBlinkCurrent();
    }
  }

  Future<void> _finishIdentify() async {
    _blinkTimer?.cancel();
    _blinkTimer = null;
    setState(() {
      _identifyMode = false;
      _blinkingSlots.clear();
    });
    if (_identified.isEmpty) return;
    await _keepOnly(List.of(_identified));
    _startSortWizard();     // 다 찾았으면 정렬로
  }

  // 걷은 대 고르기 — 중간 번호도 뺄 수 있게 직접 선택시킨다.
  // 뺀 찌는 불을 끄고, 남은 찌들의 번호를 앞으로 당긴다.
  Future<void> _showRemovePicker(int total, int removeCount) async {
    final picked = <int>{};
    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black.withValues(alpha: 0.94),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Container(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('어떤 찌를 걷으셨어요?',
                  style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Colors.white)),
              const SizedBox(height: 6),
              Text('걷은 대 $removeCount개를 골라주세요 (${picked.length}/$removeCount)',
                  style: const TextStyle(fontSize: 13, color: Colors.white54)),
              const SizedBox(height: 16),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: total,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 5,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: 1.4),
                itemBuilder: (ctx, i) {
                  final slot = i + 1;
                  final sel = picked.contains(slot);
                  return InkWell(
                    onTap: () {
                      setSheet(() {
                        if (sel) {
                          picked.remove(slot);
                        } else if (picked.length < removeCount) {
                          picked.add(slot);
                          _blinkFloat(slot);   // 어느 찌인지 물에서 확인
                        }
                      });
                    },
                    child: Container(
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: sel
                            ? Colors.redAccent
                            : Colors.white.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                            color: sel ? Colors.redAccent : Colors.transparent,
                            width: 2),
                      ),
                      child: Text('$slot',
                          style: TextStyle(
                              color: sel ? Colors.white : Colors.white70,
                              fontWeight: FontWeight.bold,
                              fontSize: 22)),
                    ),
                  );
                },
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: picked.length == removeCount
                      ? () {
                          Navigator.pop(ctx);
                          _removeFloats(picked.toList());
                        }
                      : null,
                  icon: const Icon(Icons.check, color: Colors.white, size: 24),
                  label: const Text('완료',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.bold)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    disabledBackgroundColor: Colors.white12,
                    padding: const EdgeInsets.symmetric(vertical: 15),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 고른 찌들을 목록에서 빼고 뒤 번호를 앞으로 당긴다 (왼쪽부터 순서 유지)
  Future<void> _removeFloats(List<int> slots) async {
    for (final s in slots) {
      await _sendCommandToSlot(s, 'OFF');   // 찌함에 넣을 거라 소등
    }
    final remaining = <_FloatDevice>[];
    final entries = _connectedFloats.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    for (final e in entries) {
      if (!slots.contains(e.key)) remaining.add(e.value);
    }
    setState(() {
      _connectedFloats.clear();
      for (int i = 0; i < remaining.length; i++) {
        final slot = i + 1;
        _connectedFloats[slot] = remaining[i];
        _slotAssignments[remaining[i].peripheral.uuid.toString()] = slot;
        _floatPowerStates[i] = remaining[i].isOn;
      }
      for (int i = remaining.length; i < _floatPowerStates.length; i++) {
        _floatPowerStates[i] = false;
        _floatBiteStates[i] = false;
      }
      _floatCount = remaining.isEmpty ? 1 : remaining.length;
      _bleStatus = '${slots.length}대 걷음 — 현재 ${remaining.length}대';
    });
    _saveSlotAssignments();
    _saveSettings();
  }

  // 선택 완료 — 반짝임 멈추고 LED 끄기 (대편성 동안 배터리 절약)
  Future<void> _finishPick() async {
    _pickTimer?.cancel();
    _pickTimer = null;
    setState(() => _picking = false);
    await _sendCommandToAll('OFF');
    setState(() {
      for (int i = 0; i < _floatPowerStates.length; i++) {
        _floatPowerStates[i] = false;
      }
      _bleStatus = '$_floatCount대 준비됨 — 대편성 후 정렬하세요';
    });
  }


  // 설정 — 자주 안 쓰는 항목 모음 (알림음·모드·내 찌)
  void _showSettingsSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black.withValues(alpha: 0.94),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Container(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('설정',
                style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.white)),
            const SizedBox(height: 16),
            _settingsTile(ctx, Icons.music_note, '알림음',
                _selectedSound.replaceAll('sound_', '소리 '), _showSoundSelector),
            _settingsTile(ctx, Icons.tune, '입질 모드',
                _variColor ? '변색 켜짐' : '변색 꺼짐', _showModeSelector),
            _settingsTile(
                ctx,
                _myFloats.isEmpty ? Icons.lock_open : Icons.lock,
                '내 찌 등록 · 추가',
                _myFloats.isEmpty ? '미등록' : '${_myFloats.length}개 등록됨',
                _showMyFloatsSheet),
          ],
        ),
      ),
    );
  }

  Widget _settingsTile(BuildContext ctx, IconData icon, String title,
      String value, VoidCallback onTap) {
    return ListTile(
      leading: Icon(icon, color: Colors.blueAccent, size: 26),
      title: Text(title,
          style: const TextStyle(
              color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value,
              style: const TextStyle(color: Colors.white38, fontSize: 13)),
          const Icon(Icons.chevron_right, color: Colors.white24),
        ],
      ),
      onTap: () {
        Navigator.pop(ctx);
        onTap();
      },
    );
  }


  // 내 찌 등록·잠금 관리 화면 (도난·분실 방지)
  void _showMyFloatsSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black.withValues(alpha: 0.92),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final connected = _connectedFloats.entries.toList()
            ..sort((a, b) => a.key.compareTo(b.key));
          return Container(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
            height: MediaQuery.of(ctx).size.height * 0.75,
            child: Column(
              children: [
                const Text('내 찌 등록 · 잠금',
                    style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.2,
                        color: Colors.white)),
                const SizedBox(height: 6),
                const Text('잠근 찌는 다른 사람 폰에서 사용할 수 없습니다',
                    style: TextStyle(fontSize: 11, color: Colors.white38)),
                const SizedBox(height: 4),
                Text(
                    _ownerNick.isEmpty
                        ? '등록된 내 찌: ${_myFloats.length}개'
                        : '$_ownerNick 님 · 등록된 내 찌: ${_myFloats.length}개',
                    style: const TextStyle(
                        fontSize: 12, color: Colors.amberAccent, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                // 나중에 찌를 더 산 경우 — 새 찌를 찾아 등록
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _showPairingScanner();
                    },
                    icon: const Icon(Icons.add_circle_outline,
                        size: 20, color: Colors.amberAccent),
                    label: const Text('새로 산 찌 찾기',
                        style: TextStyle(
                            color: Colors.amberAccent,
                            fontWeight: FontWeight.bold)),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.amberAccent),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                // 전체 잠금 / 해제
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: connected.isEmpty
                            ? null
                            : () async {
                                await _lockAll();
                                setSheet(() {});
                              },
                        icon: const Icon(Icons.lock, size: 18, color: Colors.white),
                        label: const Text('전체 등록·잠금',
                            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blueAccent,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _myFloats.isEmpty
                            ? null
                            : () async {
                                final ok = await _confirmUnlockAll(ctx);
                                if (ok == true) {
                                  await _unlockAll();
                                  setSheet(() {});
                                }
                              },
                        icon: const Icon(Icons.lock_open, size: 18, color: Colors.redAccent),
                        label: const Text('전체 해제 (양도)',
                            style: TextStyle(color: Colors.redAccent)),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Colors.redAccent),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                const Divider(color: Colors.white12, height: 1),
                // 연결된 찌 목록
                Expanded(
                  child: connected.isEmpty
                      ? const Center(
                          child: Text('연결된 찌가 없습니다\n(페어링에서 먼저 연결하세요)',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.white30, fontSize: 13)))
                      : ListView.builder(
                          itemCount: connected.length,
                          itemBuilder: (c, i) {
                            final slot = connected[i].key;
                            final dev = connected[i].value;
                            final name = dev.name.isEmpty ? '(이름없음)' : dev.name;
                            final mine = _myFloats.containsKey(_idOf(dev));
                            return ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(
                                mine ? Icons.lock : Icons.lock_open,
                                color: mine ? Colors.greenAccent : Colors.white30,
                              ),
                              title: Text('$slot번  $name',
                                  style: TextStyle(
                                      color: mine ? Colors.greenAccent : Colors.white70,
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold)),
                              subtitle: Text(
                                  mine ? '내 찌 (잠금됨)' : '미등록 — 누구나 사용 가능',
                                  style: TextStyle(
                                      color: mine ? Colors.greenAccent.withValues(alpha: 0.6) : Colors.white30,
                                      fontSize: 11)),
                              trailing: TextButton(
                                      onPressed: () async {
                                        if (mine) {
                                          await _unlockFloat(dev);
                                        } else {
                                          if (!await _ensureOwnerNick()) return;
                                          await _lockFloat(dev);
                                        }
                                        setSheet(() {});
                                      },
                                      child: Text(mine ? '해제' : '등록',
                                          style: TextStyle(
                                              color: mine ? Colors.redAccent : Colors.blueAccent,
                                              fontWeight: FontWeight.bold)),
                                    ),
                            );
                          },
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<bool?> _confirmUnlockAll(BuildContext ctx) {
    return showDialog<bool>(
      context: ctx,
      builder: (d) => AlertDialog(
        backgroundColor: const Color(0xFF1A1D23),
        title: const Text('전체 잠금 해제',
            style: TextStyle(color: Colors.white, fontSize: 16)),
        content: const Text(
            '잠금을 해제하면 다른 사람도 이 찌를 등록해 사용할 수 있습니다.\n중고 양도 시에만 사용하세요.',
            style: TextStyle(color: Colors.white70, fontSize: 13)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d, false),
              child: const Text('취소', style: TextStyle(color: Colors.white54))),
          TextButton(
              onPressed: () => Navigator.pop(d, true),
              child: const Text('해제', style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
  }

  void _showModeSelector() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black.withValues(alpha: 0.9),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Container(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 30),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('입질 모드',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5,
                      color: Colors.white)),
              const SizedBox(height: 6),
              const Text('일반찌처럼 쓰려면 끄세요',
                  style: TextStyle(fontSize: 11, color: Colors.white38)),
              const SizedBox(height: 16),
              // 변색 토글
              SwitchListTile(
                value: _variColor,
                activeColor: Colors.blueAccent,
                contentPadding: EdgeInsets.zero,
                title: const Text('입질 시 찌 변색',
                    style: TextStyle(color: Colors.white, fontSize: 15)),
                subtitle: Text(
                    _variColor ? '입질 오면 색이 변함' : '색 변화 없음 (일반찌)',
                    style: const TextStyle(color: Colors.white38, fontSize: 12)),
                onChanged: (v) {
                  setSheet(() {});
                  setState(() => _variColor = v);
                  _sendCommandToAll('VARI:${v ? 1 : 0}');
                  _saveSettings();
                },
              ),
              const Divider(color: Colors.white12, height: 1),
              // 폰 알림 토글
              SwitchListTile(
                value: _alertPhone,
                activeColor: Colors.blueAccent,
                contentPadding: EdgeInsets.zero,
                title: const Text('입질 시 폰 알림',
                    style: TextStyle(color: Colors.white, fontSize: 15)),
                subtitle: Text(
                    _alertPhone ? '입질 오면 폰에 알림' : '폰 알림 없음',
                    style: const TextStyle(color: Colors.white38, fontSize: 12)),
                onChanged: (v) {
                  setSheet(() {});
                  setState(() => _alertPhone = v);
                  _sendCommandToAll('ALERT:${v ? 1 : 0}');
                  _saveSettings();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showColorSelector() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black.withValues(alpha: 0.85),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(20),
        height: 220,
        child: Column(
          children: [
            const Text('SELECT COLOR',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.5,
                    color: Colors.white)),
            const SizedBox(height: 6),
            const Text('입질 시 자동 변색',
                style: TextStyle(fontSize: 11, color: Colors.white38)),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: List.generate(kColorPresets.length, (i) {
                final p = kColorPresets[i];
                final col = p.base;
                final sel = _colorIndex == i;
                return InkWell(
                  onTap: () {
                    setState(() => _colorIndex = i);
                    _sendCommandToAll('COLOR:${p.r},${p.g},${p.b}');
                    _saveSettings();
                    Navigator.pop(ctx);
                  },
                  borderRadius: BorderRadius.circular(30),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
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
                      const SizedBox(height: 8),
                      // 입질 시 변색될 색상 미리보기
                      Container(
                        width: 12, height: 12,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: p.bite,
                          border: Border.all(color: Colors.white24, width: 1),
                        ),
                      ),
                    ],
                  ),
                );
              }),
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
                        _saveSettings();
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
    _stopAutoScan();   // 자동 스캔 멈추고 수동 페어링 (중복 스캔 방지)
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
        onConnectAll: (peripherals) async {
          Navigator.pop(ctx);
          final total = peripherals.length;
          setState(() => _bleStatus = '$total개 일괄 연결 중...');
          int ok = 0;
          for (int i = 0; i < peripherals.length; i++) {
            final p = peripherals[i];
            setState(() => _bleStatus = '연결 중 ${i + 1}/$total...');
            // 연결 실패 시 2회까지 재시도 (BLE는 연속 연결 시 자주 실패함)
            for (int attempt = 0; attempt < 3; attempt++) {
              try {
                await _central.connect(p);
                ok++;
                break;
              } catch (_) {
                await Future.delayed(const Duration(milliseconds: 600));
              }
            }
            // 다음 연결 전 충분히 대기 (Android BLE 안정화)
            await Future.delayed(const Duration(milliseconds: 900));
          }
          setState(() => _bleStatus = '$ok/$total개 연결됨');
        },
        connectedUUIDs: _connectedFloats.values
            .map((d) => d.peripheral.uuid)
            .toSet(),
        myFloatNames: _myFloats.keys.toSet(),
        onDiscovered: (uuid, name) => _rememberName(uuid, name),
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
                              ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 260),
                                child: Text(_bleStatus,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: 10,
                                        color: Colors.blueAccent.withValues(alpha: 0.8),
                                        fontWeight: FontWeight.bold)),
                              ),
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
                                  for (int i = 0; i < 20; i++) { _floatPowerStates[i] = true; }
                                  for (final d in _connectedFloats.values) { d.isOn = true; }
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
                                  for (int i = 0; i < 20; i++) { _floatPowerStates[i] = false; }
                                  for (final d in _connectedFloats.values) { d.isOn = false; }
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
                          const SizedBox(width: 4),
                          // 자주 안 쓰는 항목(모드·내 찌)은 여기로 모음
                          IconButton(
                            onPressed: _showSettingsSheet,
                            icon: const Icon(Icons.settings,
                                color: Colors.white70, size: 22),
                            padding: EdgeInsets.zero,
                            constraints:
                                const BoxConstraints(minWidth: 30, minHeight: 28),
                            tooltip: '설정',
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
                      // 찌가 적을 때 너무 벌어지지 않게 한 칸 폭에 상한을 둔다
                      final rawWidth = constraints.maxWidth / _floatCount;
                      final slotWidth = rawWidth.clamp(0.0, 90.0);
                      final imgHeight = (slotWidth * 6.5)
                          .clamp(40.0, constraints.maxHeight - 56);
                      return Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: List.generate(
                          _floatCount,
                          (i) {
                            final slot = i + 1;
                            return SizedBox(
                              width: slotWidth,
                              child: DragTarget<int>(
                                onAcceptWithDetails: (details) =>
                                    _swapSlots(details.data, slot),
                                builder: (ctx, candidateData, _) {
                                  final isOver = candidateData.isNotEmpty;
                                  return Draggable<int>(
                                    data: slot,
                                    // 드래그 시작: 앱 UI 깜빡임 시작 (드롭 완료까지 유지)
                                    onDragStarted: () => _addBlink(slot, autoStop: false),
                                    // 드래그 종료(성공·취소 모두): 깜빡임 중단
                                    onDragEnd: (_) => _removeBlink(slot),
                                    // 포인터가 피드백 찌의 수평 중앙·높이 40% 지점에 위치하도록
                                    dragAnchorStrategy:
                                        pointerDragAnchorStrategy,
                                    feedback: Material(
                                      color: Colors.transparent,
                                      child: Transform.translate(
                                        // 피드백 시각 중심을 포인터에 정렬
                                        offset: Offset(
                                            -slotWidth / 2, -imgHeight * 0.4),
                                        child: SizedBox(
                                          width: slotWidth,
                                          child: Opacity(
                                            opacity: 0.85,
                                            child: _buildKreftFloat(slot,
                                                imgHeight: imgHeight),
                                          ),
                                        ),
                                      ),
                                    ),
                                    childWhenDragging: Opacity(
                                      opacity: 0.25,
                                      child: _buildKreftFloat(slot,
                                          imgHeight: imgHeight),
                                    ),
                                    child: Stack(
                                      children: [
                                        _buildKreftFloat(slot,
                                            imgHeight: imgHeight),
                                        // 드래그 대상 표시 — 레이아웃 영향 없는 오버레이
                                        if (isOver)
                                          Positioned.fill(
                                            child: IgnorePointer(
                                              child: AnimatedContainer(
                                                duration: const Duration(
                                                    milliseconds: 150),
                                                decoration: BoxDecoration(
                                                  border: Border.all(
                                                      color: Colors.blueAccent,
                                                      width: 2),
                                                  borderRadius:
                                                      BorderRadius.circular(8),
                                                ),
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                            );
                          },
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
                                onChangeEnd: (v) {
                                  _sendCommandToAll('BRIGHTNESS:${v.toStringAsFixed(2)}');
                                  _saveSettings();
                                },
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
                                onChangeEnd: (v) {
                                  _sendCommandToAll('SENSITIVITY:${(v * 5 + 1).toStringAsFixed(1)}');
                                  _saveSettings();
                                },
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
                            // 찌 고르는 중에는 같은 자리가 [선택완료]로 바뀐다
                            _picking
                                ? _BottomMenu(
                                    icon: Icons.check_circle,
                                    label: '선택완료',
                                    color: Colors.greenAccent,
                                    onTap: _finishPick)
                                : _BottomMenu(
                                    icon: Icons.grid_view,
                                    label: '찌선택',
                                    onTap: _showCountSelector),
                            _BottomMenu(
                                icon: Icons.palette_outlined,
                                label: '색상',
                                onTap: _showColorSelector),
                            _BottomMenu(
                                icon: Icons.sort,
                                label: '정렬',
                                onTap: _startSortWizard),
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
                            // 음성 제어 마이크 버튼
                            // 탭: 한 번만 듣기 / 길게 누름: 자동 연속 모드 토글
                            InkWell(
                              onTap: _speechAvailable ? _toggleListening : null,
                              onLongPress: _speechAvailable ? () {
                                setState(() => _autoListen = !_autoListen);
                                if (_autoListen) {
                                  _startListening();
                                } else {
                                  _speech.stop();
                                  setState(() { _isListening = false; _voiceText = ''; });
                                }
                              } : null,
                              borderRadius: BorderRadius.circular(10),
                              child: Container(
                                width: 70,
                                padding: const EdgeInsets.symmetric(vertical: 5),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Stack(
                                      alignment: Alignment.topRight,
                                      children: [
                                        Icon(
                                          _isListening ? Icons.mic : Icons.mic_none,
                                          color: _autoListen
                                              ? Colors.amberAccent
                                              : (_isListening
                                                  ? Colors.redAccent
                                                  : (_speechAvailable ? Colors.greenAccent : Colors.white24)),
                                          size: 30,
                                        ),
                                        // 자동 모드 표시 점
                                        if (_autoListen)
                                          Container(
                                            width: 8, height: 8,
                                            decoration: const BoxDecoration(
                                              color: Colors.amberAccent,
                                              shape: BoxShape.circle,
                                            ),
                                          ),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      _autoListen ? '자동' : (_isListening ? '듣는 중' : '음성'),
                                      style: TextStyle(
                                        color: _autoListen
                                            ? Colors.amberAccent
                                            : (_isListening
                                                ? Colors.redAccent
                                                : (_speechAvailable ? Colors.greenAccent : Colors.white24)),
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 15),
                    ],
                  ),
                ),
              ],
            ),

            // 음성 인식 결과 오버레이 (화면 중앙 상단)
            if (_voiceText.isNotEmpty)
              Positioned(
                top: 44,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.82),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: _isListening
                            ? Colors.redAccent.withValues(alpha: 0.8)
                            : Colors.greenAccent.withValues(alpha: 0.7),
                        width: 1.5,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _isListening ? Icons.mic : Icons.check_circle_outline,
                          color: _isListening ? Colors.redAccent : Colors.greenAccent,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _voiceText,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            // 정렬 마법사 오버레이
            if (_identifyMode) _buildIdentifyOverlay(),
            if (_sortMode) _buildSortOverlay(),
            // 아직 내 찌를 등록하지 않았으면 등록부터 안내
            if (_myFloats.isEmpty && !_identifyMode && !_sortMode)
              _buildWelcomeOverlay(),
          ],
        ),
      ),
    );
  }

  // 정렬 마법사 오버레이 — 깜빡이는 찌의 실제 자리 번호를 탭/음성으로 지정
  // 처음 설치했을 때 — 찌 등록부터 안내
  Widget _buildWelcomeOverlay() {
    final connected = _connectedFloats.length;
    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.92),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.phonelink_ring,
                    color: Colors.blueAccent, size: 64),
                const SizedBox(height: 20),
                const Text('KREFT 찌를 등록해 주세요',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                const Text(
                    '가지고 계신 찌를 모두 켜서 옆에 두고\n아래 버튼을 눌러주세요.\n한 번만 등록하면 다음부터 자동으로 연결됩니다.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white70, fontSize: 14, height: 1.6)),
                const SizedBox(height: 28),
                if (connected > 0)
                  Text('찌 $connected개 찾음',
                      style: const TextStyle(
                          color: Colors.greenAccent,
                          fontSize: 16,
                          fontWeight: FontWeight.bold)),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: connected > 0
                        ? () async {
                            await _lockAll();       // 닉네임 입력 + 전체 등록·잠금
                          }
                        : _showPairingScanner,
                    icon: Icon(
                        connected > 0 ? Icons.check_circle : Icons.bluetooth_searching,
                        color: Colors.white),
                    label: Text(
                        connected > 0 ? '찌 $connected개 등록하기' : '찌 찾기',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.bold)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blueAccent,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                TextButton(
                  onPressed: () => setState(() => _myFloats['__skip__'] = ''),
                  child: const Text('나중에 하기',
                      style: TextStyle(color: Colors.white38)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // 수동 확인 화면 — 깜빡이는 찌가 물에 있는지 하나씩 확인
  Widget _buildIdentifyOverlay() {
    final step = _identifyIndex + 1;
    final total = _identifyQueue.length;
    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.9),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('찌 확인  ($step / $total)',
                    style: const TextStyle(
                        color: Colors.amberAccent,
                        fontSize: 20,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 10),
                Text('찾은 찌 ${_identified.length} / $_identifyTarget',
                    style: const TextStyle(
                        color: Colors.greenAccent, fontSize: 15)),
                const SizedBox(height: 24),
                const Text('지금 깜빡이는 찌가',
                    style: TextStyle(color: Colors.white, fontSize: 17)),
                const SizedBox(height: 4),
                const Text('물에 있나요?',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                const Text('찌함 안에서 깜빡이면 [찌함에 있음]을 누르세요',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white38, fontSize: 13)),
                const SizedBox(height: 30),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => _identifyAnswer(false),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Colors.white38),
                          padding: const EdgeInsets.symmetric(vertical: 18),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                        child: const Text('찌함에 있음',
                            style: TextStyle(
                                color: Colors.white70, fontSize: 16)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () => _identifyAnswer(true),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          padding: const EdgeInsets.symmetric(vertical: 18),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                        child: const Text('물에 있음',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 17,
                                fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: _finishIdentify,
                  child: const Text('그만하기',
                      style: TextStyle(color: Colors.white38)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSortOverlay() {
    final total = _sortQueue.length;
    final step = _sortIndex + 1;
    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.88),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('🎣 찌 정렬  ($step / $total)',
                    style: const TextStyle(
                        color: Colors.amberAccent,
                        fontSize: 20,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                const Text('지금 깜빡이는 찌가 물에서 몇 번째 자리인가요?',
                    style: TextStyle(color: Colors.white, fontSize: 15)),
                const Text('숫자를 누르거나 "칠번"이라고 말하세요',
                    style: TextStyle(color: Colors.white38, fontSize: 12)),
                const SizedBox(height: 16),
                // 숫자 버튼 그리드 (1 ~ floatCount)
                Expanded(
                  child: Center(
                    child: SingleChildScrollView(
                      child: Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        alignment: WrapAlignment.center,
                        children: List.generate(_sortQueue.length, (i) {
                          final pos = i + 1;
                          final taken = _sortTargets.values.contains(pos);
                          return InkWell(
                            onTap: taken ? null : () => _sortAssign(pos),
                            borderRadius: BorderRadius.circular(12),
                            child: Container(
                              width: 58,
                              height: 58,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: taken
                                    ? Colors.white10
                                    : Colors.blueAccent.withValues(alpha: 0.25),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                    color: taken ? Colors.white24 : Colors.blueAccent,
                                    width: 2),
                              ),
                              child: Text('$pos',
                                  style: TextStyle(
                                      color: taken ? Colors.white24 : Colors.white,
                                      fontSize: 22,
                                      fontWeight: FontWeight.bold)),
                            ),
                          );
                        }),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                // 취소 버튼
                TextButton.icon(
                  onPressed: _cancelSort,
                  icon: const Icon(Icons.close, color: Colors.redAccent),
                  label: const Text('정렬 취소',
                      style: TextStyle(color: Colors.redAccent, fontSize: 15)),
                ),
              ],
            ),
          ),
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

    final isBlinking = _blinkingSlots.contains(number);

    Color ledColor = isOn ? _currentFloatColor : Colors.grey.shade800;
    double ledOpacity = isOn ? _brightnessValue.clamp(0.3, 1.0) : 0.15;
    // 밝기 곡선 보정: 100%→1.0, 50%→0.80, 30%→0.72 (camfishing_float 동일)
    final glowAlpha = isOn ? (ledOpacity * 0.4 + 0.6) : 0.0;

    if (isBite && isOn) {
      ledColor = _preset.bite;   // 입질 시 프리셋 변색 (전자찌와 동일)
      ledOpacity = 1.0;
    }
    // 깜빡임 중: 물리 찌와 동기화하여 5색 순환 (낮에도 잘 보이게)
    if (isBlinking && isOn) {
      ledColor = kColorPresets[_blinkColorIdx].base;
      ledOpacity = 1.0;
    }

    return GestureDetector(
      // 짧게 탭: 해당 찌 LED 깜빡임 + 앱 UI도 동시에 깜빡임 → 물 위에서 위치 확인
      onTap: () {
        _blinkFloat(number);
        _addBlink(number);
      },
      // 길게 누름: ON/OFF 토글 (기존 동작 유지)
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
                // 실제 찌 이미지 — 전원과 무관하게 항상 선명하게 (LED만 꺼진다)
                Image.asset(
                  'assets/images/float_kreft.png',
                  height: imgHeight,
                  fit: BoxFit.fitHeight,
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
                                Colors.white.withValues(alpha: isBite ? 1.0 : 0.95 * glowAlpha),
                                ledColor.withValues(alpha: isBite ? 0.95 : 0.85 * glowAlpha),
                                ledColor.withValues(alpha: isBite ? 0.5 : 0.35 * glowAlpha),
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
                color: isBite ? _preset.bite : Colors.black.withValues(alpha: 0.6),
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
  final Color? color;            // 강조가 필요한 버튼(선택완료 등)
  const _BottomMenu(
      {required this.icon, required this.label, this.onTap, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? Colors.white70;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 70,
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: c, size: 28),
            const SizedBox(height: 5),
            Text(label,
                style: TextStyle(
                    color: c,
                    fontSize: 12,
                    fontWeight:
                        color != null ? FontWeight.bold : FontWeight.normal)),
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
  final Future<void> Function(List<Peripheral>) onConnectAll;
  final Set<UUID> connectedUUIDs;
  final Set<String> myFloatNames;                       // 내 찌로 등록·잠금된 이름
  final void Function(String uuid, String name) onDiscovered;

  const _PairingScannerWidget({
    required this.central,
    required this.serviceUUID,
    required this.onConnect,
    required this.onConnectAll,
    required this.connectedUUIDs,
    required this.myFloatNames,
    required this.onDiscovered,
  });

  @override
  State<_PairingScannerWidget> createState() =>
      _PairingScannerWidgetState();
}

class _PairingScannerWidgetState extends State<_PairingScannerWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _radarController;
  final List<DiscoveredEventArgs> _foundDevices = [];
  Timer? _rescanTimer;
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
      final serviceUUIDs = event.advertisement.serviceUUIDs;
      // KREFT 기기만 표시 (이름 또는 서비스 UUID로 필터)
      final isKreft = name.contains('KREFT') ||
          serviceUUIDs.any((u) => u == widget.serviceUUID);
      if (!isKreft) return;
      if (name.isNotEmpty) {
        widget.onDiscovered(event.peripheral.uuid.toString(), name);
      }
      // 같은 이름은 하나만 (블루투스 주소 회전으로 중복 뜨는 것 방지)
      if (name.isNotEmpty &&
          _foundDevices.any((d) => (d.advertisement.name ?? '') == name)) {
        return;
      }
      // 이름 없는 기기는 UUID로 중복 체크
      if (name.isEmpty &&
          _foundDevices.any((d) => d.peripheral.uuid == event.peripheral.uuid)) {
        return;
      }
      setState(() => _foundDevices.add(event));
    });

    widget.central.startDiscovery();

    // 일부 안드로이드는 스캔이 조용히 멈춤 → 3초마다 재시작해 놓친 찌를 계속 수집
    _rescanTimer?.cancel();
    _rescanTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      try {
        await widget.central.stopDiscovery();
        await widget.central.startDiscovery();
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    _radarController.dispose();
    _rescanTimer?.cancel();
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
          const SizedBox(height: 16),
          // 모두 연결 버튼 — 검색된 미연결 찌를 한 번에
          Builder(builder: (ctx) {
            final unconnected = _foundDevices
                .where((e) => !widget.connectedUUIDs.contains(e.peripheral.uuid))
                .toList();
            if (unconnected.isEmpty) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () => widget.onConnectAll(
                      unconnected.map((e) => e.peripheral).toList()),
                  icon: const Icon(Icons.done_all, color: Colors.white),
                  label: Text('모두 연결 (${unconnected.length}개)',
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueAccent,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            );
          }),
          // 발견된 기기 목록
          Expanded(
            child: _foundDevices.isEmpty
                ? Center(
                    child: Text('KREFT 전자찌 검색 중...',
                        style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.3))))
                : ListView.builder(
                    itemCount: _foundDevices.length,
                    itemBuilder: (ctx, i) {
                      final event = _foundDevices[i];
                      final name = event.advertisement.name ?? 'KREFT Float';
                      final alreadyConnected = widget.connectedUUIDs
                          .contains(event.peripheral.uuid);
                      final isMine = widget.myFloatNames.contains(name);
                      // "KREFT-A001·손맛왕" → 고유번호와 주인 닉네임 분리
                      final dot = name.indexOf('·');
                      final ownerNick = dot > 0 ? name.substring(dot + 1) : '';
                      final isOthers = !isMine && ownerNick.isNotEmpty;
                      return ListTile(
                        leading: Icon(
                            isMine
                                ? Icons.lock
                                : (isOthers ? Icons.person : Icons.waves),
                            color: isMine
                                ? Colors.amberAccent
                                : (isOthers ? Colors.orangeAccent : Colors.greenAccent)),
                        title: Text(
                            isMine ? '🔒 $name' : (isOthers ? '👤 $name' : '★ $name'),
                            style: TextStyle(
                                color: isMine
                                    ? Colors.amberAccent
                                    : (isOthers ? Colors.orangeAccent : Colors.greenAccent))),
                        subtitle: Text(
                            isMine
                                ? '내 찌 · 신호 강도: ${event.rssi} dBm'
                                : (isOthers
                                    ? '$ownerNick 님의 찌 — 습득 시 캠피싱에 신고해주세요'
                                    : '신호 강도: ${event.rssi} dBm'),
                            style: TextStyle(
                                color: isOthers
                                    ? Colors.orangeAccent.withValues(alpha: 0.7)
                                    : Colors.white.withValues(alpha: 0.4),
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
                                        Colors.blueAccent.withValues(alpha: 0.2),
                                    shape: RoundedRectangleBorder(
                                        borderRadius:
                                            BorderRadius.circular(20))),
                                child: const Text('연결',
                                    style: TextStyle(color: Colors.blueAccent)),
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

