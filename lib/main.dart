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
      _floatCount    = prefs.getInt('floatCount')      ?? 10;
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
    });
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
      _connectedFloats[slot] = device;
      setState(() => _bleStatus = '${_connectedFloats.length}개 연결됨');

      // Android BLE 안정화 대기
      await Future.delayed(const Duration(milliseconds: 1000));

      // GATT 탐색 (진단용 플래그 수집)
      bool svcFound = false;
      bool notifyOk = false;
      bool cmdBound = false;
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

      // 진단: 어디서 끊겼는지 화면에 표시
      if (!svcFound) {
        setState(() => _bleStatus =
            '⚠ GATT 서비스 미발견 (특성 ${services.length}개 svc) — 찌 재광고 필요');
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

    final cmds = [
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
  void _startSortWizard() {
    if (_connectedFloats.isEmpty) {
      setState(() => _bleStatus = '⚠ 연결된 찌가 없어요 (먼저 페어링)');
      return;
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
                        _saveSettings();
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
          setState(() => _bleStatus = '${peripherals.length}개 일괄 연결 중...');
          for (final p in peripherals) {
            try {
              await _central.connect(p);
              await Future.delayed(const Duration(milliseconds: 400));
            } catch (_) {}
          }
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
                            _BottomMenu(
                                icon: Icons.tune,
                                label: '모드',
                                onTap: _showModeSelector),
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
            if (_sortMode) _buildSortOverlay(),
          ],
        ),
      ),
    );
  }

  // 정렬 마법사 오버레이 — 깜빡이는 찌의 실제 자리 번호를 탭/음성으로 지정
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
  final Future<void> Function(List<Peripheral>) onConnectAll;
  final Set<UUID> connectedUUIDs;

  const _PairingScannerWidget({
    required this.central,
    required this.serviceUUID,
    required this.onConnect,
    required this.onConnectAll,
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
      final serviceUUIDs = event.advertisement.serviceUUIDs;
      // KREFT 기기만 표시 (이름 또는 서비스 UUID로 필터)
      final isKreft = name.contains('KREFT') ||
          serviceUUIDs.any((u) => u == widget.serviceUUID);
      if (!isKreft) return;
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
                      return ListTile(
                        leading: const Icon(Icons.waves,
                            color: Colors.greenAccent),
                        title: Text(
                            '★ $name',
                            style: const TextStyle(color: Colors.greenAccent)),
                        subtitle: Text(
                            '신호 강도: ${event.rssi} dBm',
                            style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.4),
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

