import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:csv/csv.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  runApp(const AnamnesisApp());
}

class AnamnesisApp extends StatelessWidget {
  const AnamnesisApp({
    super.key,
  }); // key is unique identifier for the widget, Flutter use these keys to tell widgets apart

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Anamnesis GPT',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        // master CSS file
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3:
            true, // specify Google's Material Design 3, a rulebook for the design of the app, e.g use primary color for most important elements
      ),
      home: const AnamnesisHomePage(),
    );
  }
}

class AnamnesisHomePage extends StatefulWidget {
  const AnamnesisHomePage({super.key});

  @override
  State<AnamnesisHomePage> createState() => _AnamnesisHomePageState(); // createState is a method that returns a State object
}

class _AnamnesisHomePageState extends State<AnamnesisHomePage> {
  final TextEditingController _transcriptController =
      TextEditingController(); // TextEditingController is a class that allows you to edit text in a TextField
  bool _loading = false;
  List<Map<String, dynamic>> _results =
      []; // dynamic means the variable can be any type
  String? _error; // ? means the variable can be null
  Map<String, String> _linkIdToText = {};

  @override
  void initState() {
    super.initState();
    _loadSampleTranscript();
    _loadQuestionnaire();
  }

  Future<void> _loadSampleTranscript() async {
    // async allows program to continue running while waiting for the future to complete
    final sample = await rootBundle.loadString(
      'assets/sample_transcript.txt',
    ); // await pauses the _loadSampleTranscript function until loadString is complete, before continuing
    setState(() {
      _transcriptController.text = sample;
    });
  }

  Future<String> _loadQuestionnaire() async {
    final questionnaireStr = await rootBundle.loadString(
      'assets/questionnaire.json',
    );
    final questionnaireJson = jsonDecode(questionnaireStr);
    _linkIdToText = {};
    _extractAllQuestions(
      questionnaireJson['properties']?['item']?['items'] ??
          [], // ? is a null check, if the value in the left is null, return null, ?? is a null check, if the value is null, return the value on the right
    );
    return questionnaireStr;
  }

  void _extractAllQuestions(List<dynamic> items) {
    for (final item in items) {
      if (item is Map &&
          item.containsKey('linkId') &&
          item.containsKey('text')) {
        _linkIdToText[item['linkId']] = item['text'];
        if (item.containsKey('item') && item['item'] is List) {
          _extractAllQuestions(item['item']);
        }
      }
    }
  }

  Future<String> _loadApiKey() async {
    return await rootBundle.loadString('assets/openai_api_key.txt');
  }

  Future<void> _analyzeTranscript() async {
    setState(() {
      // lambda function, setState tells Flutter to rebuild UI with new data
      _loading = true;
      _error = null;
      _results = [];
    });
    try {
      final questionnaire = await _loadQuestionnaire();
      final apiKey = (await _loadApiKey()).trim();
      final transcript = _transcriptController.text.trim();
      final prompt = _buildPrompt(questionnaire, transcript);
      final response = await _callOpenAI(prompt, apiKey);
      setState(() {
        _results = response.map((entry) {
          if (entry['answer'] is List && (entry['answer'] as List).isNotEmpty) {
            return {
              ...entry, // ... spread all properties from the original entry
              'selectedAnswer': (entry['answer'] as List).first.toString(),
            };
          }
          return entry;
        }).toList();
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
      });
    } finally {
      setState(() {
        _loading = false;
      });
    }
  }

  String _buildPrompt(String questionnaire, String transcript) {
    return '''You are a trained nurse in a hospital. You are specifically trained to take anamneses (medical histories) from patients.\nPlease analyze which questions from the JSON were addressed and what the answers are. For some questions, the JSON provides a list of possible answers — in these cases, please choose one of them. Return your answers as a simple JSON file, which contains a list of entries with each question's linkId and your answer. Do not provide any explanations for your answers. Only return a JSON array of answers, with no explanation, no markdown, and no code block. Do not include any text before or after the JSON.\n\nQuestionnaire JSON:\n$questionnaire\n\nTranscript:\n$transcript''';
  }

  Future<List<Map<String, dynamic>>> _callOpenAI(
    String prompt,
    String apiKey,
  ) async {
    final url = Uri.parse('https://api.openai.com/v1/chat/completions');
    final response = await http.post(
      url,
      headers: {
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        "model": "gpt-4-1106-preview",
        "messages": [
          {
            "role": "system",
            "content": "You are a helpful assistant.",
          }, // system role is used to set the behavior of the assistant
          {
            "role": "user",
            "content": prompt,
          }, // user role is used to send the user's message to the assistant
        ],
        "max_tokens": 4096,
        "temperature":
            0.2, // 0 means always give similar answer, 1.0 means give different answers
      }),
    );
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      final content = data['choices'][0]['message']['content'];
      // Try to parse the content as JSON
      try {
        final parsed = jsonDecode(content);
        if (parsed is List) {
          return List<Map<String, dynamic>>.from(parsed);
        } else if (parsed is Map && parsed.containsKey('answers')) {
          // if the response is a map and contains the key 'answers'
          return List<Map<String, dynamic>>.from(parsed['answers']);
        } else {
          throw Exception('Unexpected response format.');
        }
      } catch (e) {
        throw Exception('Failed to parse response: $content');
      }
    } else {
      throw Exception(
        'OpenAI API error: ${response.statusCode} ${response.body}',
      );
    }
  }

  Future<void> _exportCsv() async {
    if (_results.isEmpty) return;
    final rows = [
      ['Question', 'Answer'],
      ..._results.map(
        (e) => [
          _linkIdToText[e['linkId']] ?? e['linkId'] ?? '',
          e['selectedAnswer'] ??
              (e['answer'] is List
                  ? (e['answer'] as List).join(', ')
                  : e['answer'] ?? ''),
        ],
      ),
    ];
    final csv = const ListToCsvConverter().convert(rows);
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/anamnesis_results.csv');
    await file.writeAsString(csv);
    await Share.shareXFiles([XFile(file.path)], text: 'Anamnesis Results');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Anamnesis GPT'),
        actions: [
          IconButton(
            icon: const Icon(Icons.check),
            tooltip: 'Analyze',
            onPressed: _loading ? null : _analyzeTranscript,
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: IntrinsicHeight(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: _transcriptController,
                        maxLines: 8,
                        decoration: const InputDecoration(
                          labelText: 'Paste or edit transcript here',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (_loading)
                        const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SizedBox(
                              width: 32,
                              height: 32,
                              child: CircularProgressIndicator(strokeWidth: 3),
                            ),
                          ],
                        ),
                      if (_error != null) ...[
                        Text(
                          'Error: $_error',
                          style: const TextStyle(color: Colors.red),
                        ),
                        const SizedBox(height: 8),
                      ],
                      if (_results.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        SizedBox(
                          height: 300, // Fixed height for the results list
                          child: ListView.separated(
                            itemCount: _results.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 8),
                            itemBuilder: (context, index) {
                              final entry = _results[index];
                              final questionText =
                                  _linkIdToText[entry['linkId']] ??
                                  entry['linkId'] ??
                                  '';
                              return Card(
                                elevation: 2,
                                margin: EdgeInsets.zero,
                                child: Padding(
                                  padding: const EdgeInsets.all(12.0),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        questionText,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 16,
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      entry['answer'] is List
                                          ? DropdownButton<String>(
                                              value:
                                                  entry['selectedAnswer'] ??
                                                  (entry['answer'] as List)
                                                      .first
                                                      .toString(),
                                              items: (entry['answer'] as List)
                                                  .map<
                                                    DropdownMenuItem<String>
                                                  >(
                                                    (item) => DropdownMenuItem(
                                                      value: item.toString(),
                                                      child: Text(
                                                        item.toString(),
                                                      ),
                                                    ),
                                                  )
                                                  .toList(),
                                              onChanged: (value) {
                                                setState(() {
                                                  entry['selectedAnswer'] =
                                                      value;
                                                });
                                              },
                                            )
                                          : Text(
                                              entry['answer']?.toString() ?? '',
                                              style: const TextStyle(
                                                fontSize: 15,
                                              ),
                                            ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: 8),
                        ElevatedButton.icon(
                          icon: const Icon(Icons.share),
                          label: const Text('Share as CSV'),
                          onPressed: _exportCsv,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
