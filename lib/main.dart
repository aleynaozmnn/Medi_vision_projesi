import 'dart:async';
import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

void main() {
  runApp(const MediVisionApp());
}

class MediVisionApp extends StatelessWidget {
  const MediVisionApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Medi-Vision',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0B1220),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF14B8A6),
          brightness: Brightness.dark,
        ),
      ),
      home: const HomePage(),
    );
  }
}

class ReminderItem {
  final String medicineName;
  final String dose;
  final String form;
  final String time;
  bool isActive;
  String? lastTriggeredKey;

  ReminderItem({
    required this.medicineName,
    required this.dose,
    required this.form,
    required this.time,
    this.isActive = true,
    this.lastTriggeredKey,
  });
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
 
static const String apiKey = String.fromEnvironment('geminiApiKey', defaultValue: '');

  final AudioPlayer _audioPlayer = AudioPlayer();
  final ImagePicker _picker = ImagePicker();
  final FlutterTts _flutterTts = FlutterTts();

  XFile? _selectedImage;

  bool _isLoading = false;
  bool _isSpeaking = false;

  String _analysisResult = '';
  String _errorText = '';

  String _medicineName = '';
  String _dose = '';
  String _form = '';
  String _summary = '';
  String _warning = '';

  final List<ReminderItem> _reminders = [];
  Timer? _reminderTimer;

  @override
  void initState() {
    super.initState();
    _setupTts();
    _setupAudio();
    _startReminderChecker();
  }

  Future<void> _setupTts() async {
    await _flutterTts.setLanguage('tr-TR');
    await _flutterTts.setSpeechRate(0.45);
    await _flutterTts.setPitch(1.0);

    _flutterTts.setStartHandler(() {
      if (!mounted) return;
      setState(() {
        _isSpeaking = true;
      });
    });

    _flutterTts.setCompletionHandler(() {
      if (!mounted) return;
      setState(() {
        _isSpeaking = false;
      });
    });

    _flutterTts.setCancelHandler(() {
      if (!mounted) return;
      setState(() {
        _isSpeaking = false;
      });
    });

    _flutterTts.setErrorHandler((message) {
      if (!mounted) return;

      final msg = message.toLowerCase();

      setState(() {
        _isSpeaking = false;
        if (msg.contains('interrupted') || msg.contains('canceled')) {
          return;
        }
        _errorText = 'Sesli okuma hatası: $message';
      });
    });
  }

  Future<void> _setupAudio() async {
    await _audioPlayer.setReleaseMode(ReleaseMode.stop);
  }

  Future<void> _playAlarmSound() async {
    try {
      await _audioPlayer.stop();
      await _audioPlayer.play(AssetSource('audio.wav'));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorText = 'Alarm sesi çalınamadı: $e';
      });
    }
  }

  Future<void> _stopAlarmSound() async {
    await _audioPlayer.stop();
  }

  void _startReminderChecker() {
    _reminderTimer?.cancel();

    _reminderTimer = Timer.periodic(const Duration(seconds: 20), (timer) async {
      if (!mounted || _reminders.isEmpty) return;

      final now = DateTime.now();
      final currentTime =
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
      final todayKey =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}-$currentTime';

      for (final reminder in _reminders) {
        if (!reminder.isActive) continue;

        if (reminder.time == currentTime &&
            reminder.lastTriggeredKey != todayKey) {
          reminder.lastTriggeredKey = todayKey;

          await _playAlarmSound();

          if (!mounted) return;

          ScaffoldMessenger.of(context).clearSnackBars();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              duration: const Duration(seconds: 5),
              behavior: SnackBarBehavior.floating,
              margin: const EdgeInsets.all(20),
              backgroundColor: const Color(0xFF1E293B),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              content: Row(
                children: [
                  const Icon(
                    Icons.alarm_on_rounded,
                    color: Color(0xFFFBBF24),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Hatırlatma: ${reminder.medicineName} (${reminder.dose}) saati geldi.',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ],
              ),
              action: SnackBarAction(
                label: 'Durdur',
                textColor: const Color(0xFF5EEAD4),
                onPressed: () async {
                  await _stopAlarmSound();
                },
              ),
            ),
          );
        }
      }
    });
  }

  Future<void> _pickImage() async {
    final XFile? pickedFile = await _picker.pickImage(
      source: ImageSource.gallery,
    );

    if (pickedFile != null) {
      await _flutterTts.stop();

      setState(() {
        _selectedImage = pickedFile;
        _analysisResult = '';
        _errorText = '';
        _medicineName = '';
        _dose = '';
        _form = '';
        _summary = '';
        _warning = '';
        _isSpeaking = false;
      });
    }
  }

  void _parseAnalysisResult(String text) {
    _medicineName = '';
    _dose = '';
    _form = '';
    _summary = '';
    _warning = '';

    final lines = text.split('\n');

    String summaryText = '';
    String warningText = '';

    bool isSummarySection = false;
    bool isWarningSection = false;

    for (final rawLine in lines) {
      String line = rawLine.trim();

      if (line.isEmpty) continue;

      line = line
          .replaceAll('**', '')
          .replaceAll('*', '')
          .replaceAll('•', '')
          .trim();

      if (line.startsWith('İlaç Adı:')) {
        _medicineName = line.split('İlaç Adı:').last.trim();
        isSummarySection = false;
        isWarningSection = false;
      } else if (line.startsWith('Doz:')) {
        _dose = line.split('Doz:').last.trim();
        isSummarySection = false;
        isWarningSection = false;
      } else if (line.startsWith('Form:')) {
        _form = line.split('Form:').last.trim();
        isSummarySection = false;
        isWarningSection = false;
      } else if (line.startsWith('Kutudaki Metin Özeti:')) {
        summaryText = line.split('Kutudaki Metin Özeti:').last.trim();
        isSummarySection = true;
        isWarningSection = false;
      } else if (line.startsWith('Uyarı:')) {
        warningText = line.split('Uyarı:').last.trim();
        isSummarySection = false;
        isWarningSection = true;
      } else {
        if (isSummarySection) {
          summaryText = summaryText.isEmpty ? line : '$summaryText $line';
        } else if (isWarningSection) {
          warningText = warningText.isEmpty ? line : '$warningText $line';
        }
      }
    }

    _summary = summaryText.trim();
    _warning = warningText.trim();
  }

  Future<void> _analyzeImage() async {
    if (_selectedImage == null) {
      setState(() {
        _errorText = 'Önce bir ilaç görseli seçmelisin.';
      });
      return;
    }

    if (apiKey.isEmpty) {
  setState(() {
    _errorText = 'Hata: API anahtarı sisteme gömülememiş.';
  });
  return;
}

    await _flutterTts.stop();

    setState(() {
      _isLoading = true;
      _analysisResult = '';
      _errorText = '';
      _medicineName = '';
      _dose = '';
      _form = '';
      _summary = '';
      _warning = '';
      _isSpeaking = false;
    });

    try {
      final bytes = await _selectedImage!.readAsBytes();
      final base64Image = base64Encode(bytes);

       final uri = Uri.parse(
  'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$apiKey',
);

      final requestBody = {
        "contents": [
          {
            "parts": [
              {
                "text": """
Bu bir ilaç kutusu görseli.

Lütfen yalnızca görselde gördüğün bilgilere göre Türkçe ve sade bir özet ver.
Aşağıdaki başlıklarla cevapla:

İlaç Adı:
Doz:
Form:
Kutudaki Metin Özeti:
Uyarı:

Kurallar:
- Emin olmadığın bilgiyi 'Net okunamadı' diye yaz.
- Doktor tavsiyesi verme.
- Görselde olmayan bilgi uydurma.
"""
              },
              {
                "inline_data": {
                  "mime_type": "image/jpeg",
                  "data": base64Image,
                }
              }
            ]
          }
        ]
      };

      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(requestBody),
      );

      final responseData = jsonDecode(response.body);

      if (response.statusCode == 200) {
        final text =
            responseData['candidates']?[0]?['content']?['parts']?[0]?['text'];

        setState(() {
          _analysisResult = text ?? 'Yanıt alındı ama metin boş döndü.';
          if (text != null) {
            _parseAnalysisResult(text);
          }
        });
      } else {
        final message = responseData['error']?['message'] ?? 'Bilinmeyen hata';
        setState(() {
          _errorText = 'API hatası: $message';
        });
      }
    } catch (e) {
      setState(() {
        _errorText = 'Bir hata oluştu: $e';
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  String _buildSpeechText() {
    return '''
İlaç adı: ${_medicineName.isEmpty ? 'Bulunamadı' : _medicineName}.
Doz: ${_dose.isEmpty ? 'Bulunamadı' : _dose}.
Form: ${_form.isEmpty ? 'Bulunamadı' : _form}.
Uyarı: ${_warning.isEmpty ? 'Bulunamadı' : _warning}.
''';
  }

  Future<void> _speakAnalysis() async {
    if (_analysisResult.isEmpty) {
      setState(() {
        _errorText = 'Önce analiz yapmalısın.';
      });
      return;
    }

    await _flutterTts.stop();
    await _flutterTts.speak(_buildSpeechText());
  }

  Future<void> _stopSpeaking() async {
    setState(() {
      _errorText = '';
      _isSpeaking = false;
    });

    await _flutterTts.stop();
  }

  Future<void> _addReminder() async {
    if (_medicineName.isEmpty) {
      setState(() {
        _errorText = 'Önce ilaç analizini yapmalısın.';
      });
      return;
    }

    final TimeOfDay? selectedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            timePickerTheme: const TimePickerThemeData(
              backgroundColor: Color(0xFF111827),
              hourMinuteTextColor: Colors.white,
              dialHandColor: Color(0xFF14B8A6),
              dialBackgroundColor: Color(0xFF0F172A),
              entryModeIconColor: Color(0xFF5EEAD4),
            ),
          ),
          child: child!,
        );
      },
    );

    if (selectedTime == null) return;

    final formattedTime =
        '${selectedTime.hour.toString().padLeft(2, '0')}:${selectedTime.minute.toString().padLeft(2, '0')}';

    setState(() {
      _reminders.add(
        ReminderItem(
          medicineName: _medicineName.isEmpty ? 'Bilinmeyen İlaç' : _medicineName,
          dose: _dose.isEmpty ? 'Doz yok' : _dose,
          form: _form.isEmpty ? 'Form yok' : _form,
          time: formattedTime,
        ),
      );
      _errorText = '';
    });

    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(20),
        backgroundColor: const Color(0xFF1E293B),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        content: Text(
          '$formattedTime için ${_medicineName.isEmpty ? 'ilaç' : _medicineName} hatırlatıcısı eklendi.',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  void _removeReminder(int index) {
    final removed = _reminders[index];

    setState(() {
      _reminders.removeAt(index);
    });

    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(20),
        backgroundColor: const Color(0xFF3F1D1D),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        content: Text(
          '${removed.medicineName} hatırlatıcısı silindi.',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _infoTile(String title, String value) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF1E293B)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: Color(0xFF5EEAD4),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value.isEmpty ? 'Bulunamadı' : value,
            style: const TextStyle(
              fontSize: 15,
              height: 1.5,
              color: Color(0xFFE5E7EB),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF111827), Color(0xFF0F172A)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: const Color(0xFF1F2937)),
        boxShadow: const [
          BoxShadow(
            color: Colors.black26,
            blurRadius: 18,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              color: const Color(0xFF0F766E).withOpacity(0.18),
              borderRadius: BorderRadius.circular(22),
            ),
            child: const Icon(
              Icons.medication_liquid_rounded,
              size: 44,
              color: Color(0xFF2DD4BF),
            ),
          ),
          const SizedBox(height: 18),
          const Text(
            'Medi-Vision',
            style: TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w800,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Akıllı İlaç Rehberi',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: Color(0xFF5EEAD4),
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            'İlaç kutusunun görselini yükle, ardından Gemini ile kutu üzerindeki metni analiz edip sade bir özet al.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 15,
              height: 1.6,
              color: Color(0xFFCBD5E1),
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            height: 58,
            child: ElevatedButton.icon(
              onPressed: _pickImage,
              icon: const Icon(Icons.upload_rounded),
              label: const Text(
                'İlaç Görseli Yükle',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF14B8A6),
                foregroundColor: const Color(0xFF062C30),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            height: 58,
            child: OutlinedButton.icon(
              onPressed: _isLoading ? null : _analyzeImage,
              icon: const Icon(Icons.auto_awesome_rounded),
              label: Text(
                _isLoading ? 'Analiz ediliyor...' : 'Metni Analiz Et',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF5EEAD4),
                side: const BorderSide(color: Color(0xFF134E4A), width: 1.4),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildImageCard() {
    if (_selectedImage == null) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFF1F2937)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.image_outlined, color: Color(0xFF5EEAD4)),
              SizedBox(width: 8),
              Text(
                'Seçilen Görsel',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: Image.network(
              _selectedImage!.path,
              height: 320,
              width: double.infinity,
              fit: BoxFit.contain,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSpeechButtons() {
    if (_analysisResult.isEmpty || _errorText.isNotEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFF1F2937)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.record_voice_over_rounded, color: Color(0xFF5EEAD4)),
              SizedBox(width: 8),
              Text(
                'Sesli Okuma',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            height: 54,
            child: ElevatedButton.icon(
              onPressed: _isSpeaking ? null : _speakAnalysis,
              icon: const Icon(Icons.volume_up_rounded),
              label: const Text(
                'Sonucu Sesli Oku',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF22C55E),
                foregroundColor: const Color(0xFF052E16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 54,
            child: OutlinedButton.icon(
              onPressed: _isSpeaking ? _stopSpeaking : null,
              icon: const Icon(Icons.stop_circle_outlined),
              label: const Text(
                'Sesli Okumayı Durdur',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFFFCA5A5),
                side: const BorderSide(color: Color(0xFF7F1D1D), width: 1.4),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReminderSection() {
    if (_analysisResult.isEmpty || _errorText.isNotEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFF1F2937)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.alarm_rounded, color: Color(0xFF5EEAD4)),
              SizedBox(width: 8),
              Text(
                'Hatırlatıcı',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            height: 54,
            child: ElevatedButton.icon(
              onPressed: _addReminder,
              icon: const Icon(Icons.add_alarm_rounded),
              label: const Text(
                'Hatırlatıcı Ekle',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFF59E0B),
                foregroundColor: const Color(0xFF3B1F00),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (_reminders.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF1E293B)),
              ),
              child: const Text(
                'Henüz hatırlatıcı eklenmedi.',
                style: TextStyle(
                  color: Color(0xFFE5E7EB),
                  fontSize: 15,
                ),
              ),
            )
          else
            Column(
              children: List.generate(_reminders.length, (index) {
                final reminder = _reminders[index];

                return Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0F172A),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFF1E293B)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        reminder.medicineName,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Doz: ${reminder.dose} • Form: ${reminder.form}',
                        style: const TextStyle(
                          fontSize: 14,
                          color: Color(0xFFCBD5E1),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Saat: ${reminder.time}',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF5EEAD4),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text(
                                'Aktif',
                                style: TextStyle(color: Colors.white),
                              ),
                              value: reminder.isActive,
                              onChanged: (value) {
                                setState(() {
                                  reminder.isActive = value;
                                });
                              },
                            ),
                          ),
                          IconButton(
                            onPressed: () => _removeReminder(index),
                            icon: const Icon(
                              Icons.delete_outline_rounded,
                              color: Colors.redAccent,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              }),
            ),
        ],
      ),
    );
  }

  Widget _buildResultCard() {
    if (_analysisResult.isEmpty && _errorText.isEmpty && !_isLoading) {
      return const SizedBox.shrink();
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFF1F2937)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                _errorText.isNotEmpty
                    ? Icons.error_outline_rounded
                    : Icons.text_snippet_outlined,
                color: _errorText.isNotEmpty
                    ? Colors.redAccent
                    : const Color(0xFF5EEAD4),
              ),
              const SizedBox(width: 8),
              Text(
                _errorText.isNotEmpty ? 'Hata' : 'Analiz Sonucu',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (_isLoading)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(12),
                child: CircularProgressIndicator(),
              ),
            )
          else if (_errorText.isNotEmpty)
            SelectableText(
              _errorText,
              style: const TextStyle(
                fontSize: 15,
                height: 1.6,
                color: Colors.redAccent,
              ),
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _infoTile('İlaç Adı', _medicineName),
                _infoTile('Doz', _dose),
                _infoTile('Form', _form),
                _infoTile('Özet', _summary),
                _infoTile('Uyarı', _warning),
              ],
            ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _reminderTimer?.cancel();
    _flutterTts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF020617), Color(0xFF0B1220)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: Column(
                  children: [
                    _buildTopCard(),
                    const SizedBox(height: 20),
                    _buildImageCard(),
                    const SizedBox(height: 20),
                    _buildResultCard(),
                    const SizedBox(height: 20),
                    _buildSpeechButtons(),
                    const SizedBox(height: 20),
                    _buildReminderSection(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}