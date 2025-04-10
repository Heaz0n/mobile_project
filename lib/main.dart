import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'package:audioplayers/audioplayers.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:lottie/lottie.dart';
import 'package:confetti/confetti.dart';
import 'package:percent_indicator/percent_indicator.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  await Hive.openBox('quizBox');
  await Hive.openBox('achievementsBox');
  await Hive.openBox('statsBox');
  await Hive.openBox('settingsBox');
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp])
      .then((_) {
    runApp(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider(create: (context) => AudioPlayer()),
          RepositoryProvider(create: (context) => FlutterTts()),
          RepositoryProvider(create: (context) => QuizRepository()),
        ],
        child: const QuizApp(),
      ),
    );
  });
}

class QuizRepository {
  final Map<String, int> categories = {
    'Любая категория': 0,
    'Общие знания': 9,
    'Книги': 10,
    'Фильмы': 11,
    'Музыка': 12,
    'Наука': 17,
    'Компьютеры': 18,
    'Математика': 19,
    'Спорт': 21,
    'История': 23,
    'Искусство': 25,
    'География': 22,
    'Политика': 24,
  };

  final Map<String, String> languages = {
    'Русский': 'ru',
    'Английский': 'en',
  };

  final Map<String, String> difficultyLevels = {
    'Легкая': 'easy',
    'Средняя': 'medium',
    'Сложная': 'hard',
    'Любая': 'any',
  };

  Future<List<QuizQuestion>> fetchQuestions({
    required String category,
    required String difficulty,
    int amount = 10,
  }) async {
    final box = await Hive.openBox('quizBox');
    final cacheKey = '${category}_${difficulty}_$amount';
    
   if (box.containsKey(cacheKey)) {
  final cachedData = box.get(cacheKey);
  final now = DateTime.now();
  final cachedTime = box.get('${cacheKey}_time');
  
  if (cachedTime != null && now.difference(cachedTime as DateTime).inDays < 1) {
    final List<dynamic> dataList = cachedData is List ? cachedData : [];
    return dataList.map((item) {
      final Map<String, dynamic> itemMap = item is Map ? Map<String, dynamic>.from(item) : {};
      return QuizQuestion.fromMap(itemMap);
    }).toList();
  }
}

    int? categoryId = categories[category];
    String url = 'https://opentdb.com/api.php?amount=$amount&type=multiple';
    
    if (categoryId != null && categoryId > 0) {
      url += '&category=$categoryId';
    }
    
    if (difficulty != 'Любая') {
      url += '&difficulty=${difficultyLevels[difficulty]}';
    }

    try {
      final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
      
      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        final results = data['results'] as List<dynamic>;
        
        final questions = results.map((item) => QuizQuestion.fromJson(item as Map<String, dynamic>)).toList();
        
        for (var question in questions) {
          await question.fetchWikipediaInfo();
          await question.fetchImage();
          await question.generateHints();
        }
        
        await box.put(cacheKey, questions.map((q) => q.toMap()).toList());
        await box.put('${cacheKey}_time', DateTime.now());
        
        return questions;
      } else {
        throw Exception('Ошибка загрузки: ${response.statusCode}');
      }
    } catch (e) {
      if (box.containsKey(cacheKey)) {
        final cachedData = box.get(cacheKey) as List<dynamic>;
        return cachedData.map((item) => QuizQuestion.fromMap(item as Map<String, dynamic>)).toList();
      }
      throw Exception('Ошибка: $e');
    }
  }

Future<void> saveGameResult({
  required int score,
  required int totalQuestions,
  required String category,
  required String difficulty,
}) async {
  final box = await Hive.openBox('statsBox');
  final now = DateTime.now();
  final gameId = now.millisecondsSinceEpoch.toString();
  
  final gameData = <String, dynamic>{
    'id': gameId,
    'date': now.toIso8601String(),
    'score': score,
    'total': totalQuestions,
    'category': category,
    'difficulty': difficulty,
    'percentage': (score / (totalQuestions * 10)) * 100,
  };
  
  // Получаем историю игр и приводим к правильному типу
  final history = List<Map<String, dynamic>>.from(
    box.get('gameHistory', defaultValue: <Map<String, dynamic>>[]) as List
  );
  history.add(gameData);
  await box.put('gameHistory', history);
  
  // Обновляем общую статистику
  final totalGames = box.get('totalGames', defaultValue: 0) as int;
  final totalCorrect = box.get('totalCorrect', defaultValue: 0) as int;
  final totalPoints = box.get('totalPoints', defaultValue: 0) as int;
  
  await box.put('totalGames', totalGames + 1);
  await box.put('totalCorrect', totalCorrect + score ~/ 10);
  await box.put('totalPoints', totalPoints + score);
  
  await _checkAchievements(box, score, totalQuestions, category);
}

  Future<void> _checkAchievements(Box box, int score, int totalQuestions, String category) async {
    final achievementsBox = await Hive.openBox('achievementsBox');
    final percentage = (score / (totalQuestions * 10)) * 100;
    
    if (!achievementsBox.containsKey('firstGame')) {
      achievementsBox.put('firstGame', true);
      _showAchievementNotification('Первая игра!', 'Вы сыграли свою первую викторину');
    }
    
    if (percentage >= 100 && !achievementsBox.containsKey('perfectScore')) {
      achievementsBox.put('perfectScore', true);
      _showAchievementNotification('Идеально!', 'Вы ответили правильно на все вопросы');
    }
    
    if (!achievementsBox.containsKey('category_$category')) {
      final categoryGames = box.get('category_$category', defaultValue: 0) as int;
      if (categoryGames >= 5) {
        achievementsBox.put('category_$category', true);
        _showAchievementNotification('Эксперт по $category', 'Вы сыграли 5 игр в этой категории');
      }
    }
  }

  void _showAchievementNotification(String title, String message) {
    debugPrint('Достижение получено: $title - $message');
  }
}

class QuizApp extends StatelessWidget {
  const QuizApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Умная викторина PRO',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6C63FF),
          brightness: Brightness.light,
          primary: const Color(0xFF6C63FF),
          secondary: const Color(0xFFFF6584),
          tertiary: const Color(0xFF42A5F5),
          surface: const Color(0xFFF5F5F5),
        ),
        useMaterial3: true,
        cardTheme: CardTheme(
          elevation: 2,
          margin: const EdgeInsets.all(12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        appBarTheme: const AppBarTheme(
          centerTitle: true,
          elevation: 0,
          scrolledUnderElevation: 4,
        ),
        textTheme: const TextTheme(
          displayLarge: TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
          displayMedium: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          bodyLarge: TextStyle(fontSize: 18),
          bodyMedium: TextStyle(fontSize: 16),
          bodySmall: TextStyle(fontSize: 14),
        ),
        floatingActionButtonTheme: FloatingActionButtonThemeData(
          backgroundColor: const Color(0xFF6C63FF),
          elevation: 4,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

class QuizQuestion {
  final String question;
  final List<String> options;
  final int correctIndex;
  final String category;
  final String difficulty;
  String? imageUrl;
  String? audioUrl;
  String translatedQuestion;
  List<String> translatedOptions;
  String? explanation;
  String? wikipediaUrl;
  List<String>? hints;
  int timeLimit;

  QuizQuestion({
    required this.question,
    required this.options,
    required this.correctIndex,
    required this.category,
    required this.difficulty,
    this.imageUrl,
    this.audioUrl,
    this.translatedQuestion = '',
    this.translatedOptions = const [],
    this.explanation,
    this.wikipediaUrl,
    this.hints,
    this.timeLimit = 30,
  });

  factory QuizQuestion.fromJson(Map<String, dynamic> json) {
    String decodeHtml(String html) {
      return html
          .replaceAll('&quot;', '"')
          .replaceAll('&#039;', "'")
          .replaceAll('&amp;', '&')
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>');
    }

    final question = decodeHtml(json['question'] as String);
    final correctAnswer = decodeHtml(json['correct_answer'] as String);
    final incorrectAnswers = (json['incorrect_answers'] as List<dynamic>)
        .map((answer) => decodeHtml(answer as String))
        .toList();

    final allAnswers = [...incorrectAnswers, correctAnswer]..shuffle();
    final correctIndex = allAnswers.indexOf(correctAnswer);

    int timeLimit;
    switch (json['difficulty'] as String) {
      case 'easy':
        timeLimit = 45;
        break;
      case 'medium':
        timeLimit = 30;
        break;
      case 'hard':
        timeLimit = 20;
        break;
      default:
        timeLimit = 30;
    }

    return QuizQuestion(
      question: question,
      options: allAnswers,
      correctIndex: correctIndex,
      category: json['category'] as String,
      difficulty: json['difficulty'] as String,
      timeLimit: timeLimit,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'question': question,
      'options': options,
      'correctIndex': correctIndex,
      'category': category,
      'difficulty': difficulty,
      'imageUrl': imageUrl,
      'audioUrl': audioUrl,
      'translatedQuestion': translatedQuestion,
      'translatedOptions': translatedOptions,
      'explanation': explanation,
      'wikipediaUrl': wikipediaUrl,
      'hints': hints,
      'timeLimit': timeLimit,
    };
  }

  factory QuizQuestion.fromMap(Map<String, dynamic> map) {
    return QuizQuestion(
      question: map['question'] as String,
      options: List<String>.from(map['options'] as List),
      correctIndex: map['correctIndex'] as int,
      category: map['category'] as String,
      difficulty: map['difficulty'] as String,
      imageUrl: map['imageUrl'] as String?,
      audioUrl: map['audioUrl'] as String?,
      translatedQuestion: map['translatedQuestion'] as String? ?? '',
      translatedOptions: List<String>.from(map['translatedOptions'] as List? ?? []),
      explanation: map['explanation'] as String?,
      wikipediaUrl: map['wikipediaUrl'] as String?,
      hints: map['hints'] != null ? List<String>.from(map['hints'] as List) : null,
      timeLimit: map['timeLimit'] as int? ?? 30,
    );
  }

  Future<void> translate(String targetLang) async {
    try {
      final questionResponse = await http.get(
        Uri.parse('https://api.mymemory.translated.net/get?q=${Uri.encodeComponent(question)}&langpair=en|$targetLang'),
      );

      if (questionResponse.statusCode == 200) {
        final questionData = json.decode(questionResponse.body) as Map<String, dynamic>;
        translatedQuestion = questionData['responseData']['translatedText'] as String? ?? question;
      }

      translatedOptions = [];
      for (var option in options) {
        final optionResponse = await http.get(
          Uri.parse('https://api.mymemory.translated.net/get?q=${Uri.encodeComponent(option)}&langpair=en|$targetLang'),
        );

        if (optionResponse.statusCode == 200) {
          final optionData = json.decode(optionResponse.body) as Map<String, dynamic>;
          translatedOptions.add(optionData['responseData']['translatedText'] as String? ?? option);
        } else {
          translatedOptions.add(option);
        }
      }
    } catch (e) {
      debugPrint('Translation error: $e');
      translatedQuestion = question;
      translatedOptions = options;
    }
  }

  Future<void> fetchWikipediaInfo() async {
    try {
      final response = await http.get(
        Uri.parse('https://en.wikipedia.org/w/api.php?action=query&format=json&prop=extracts|pageimages&exintro&explaintext&redirects=1&titles=${Uri.encodeComponent(question)}'),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        final pages = data['query']['pages'] as Map<String, dynamic>;
        final pageId = pages.keys.first;
        
        if (pageId != '-1') {
          final page = pages[pageId] as Map<String, dynamic>;
          explanation = page['extract'] as String?;
          
          final urlResponse = await http.get(
            Uri.parse('https://en.wikipedia.org/w/api.php?action=query&format=json&prop=info&inprop=url&redirects=1&titles=${Uri.encodeComponent(question)}'),
          );
          
          if (urlResponse.statusCode == 200) {
            final urlData = json.decode(urlResponse.body) as Map<String, dynamic>;
            final urlPages = urlData['query']['pages'] as Map<String, dynamic>;
            final urlPageId = urlPages.keys.first;
            wikipediaUrl = urlPages[urlPageId]['fullurl'] as String?;
          }
        }
      }
    } catch (e) {
      debugPrint('Wikipedia error: $e');
    }
  }

  Future<void> fetchImage() async {
    try {
      final response = await http.get(
        Uri.parse('https://pixabay.com/api/?key=17555168-4a24b1a4e5c3b1ccf9a2d0b3d&q=${Uri.encodeComponent(category)}&image_type=photo&per_page=3'),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        if (data['hits'] != null && (data['hits'] as List).isNotEmpty) {
          imageUrl = (data['hits'] as List<dynamic>)[0]['webformatURL'] as String?;
        }
      }
    } catch (e) {
      debugPrint('Image fetch error: $e');
    }
  }

  Future<void> generateHints() async {
  hints = [];
  
  final correctAnswer = options[correctIndex];
  hints?.add('Первая буква: ${correctAnswer[0].toUpperCase()}');
  hints?.add('Категория: $category');
  hints?.add('Длина ответа: ${correctAnswer.length} букв');
}
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _scaleAnimation;
  late Animation<double> _fadeAnimation;
  int _currentPage = 0;
  final PageController _pageController = PageController();

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _scaleAnimation = Tween<double>(begin: 0.95, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOutQuint),
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );
    _animationController.forward();
  }

  @override
  void dispose() {
    _animationController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isSmallScreen = screenWidth < 600;

    return Scaffold(
      body: SafeArea(
        child: ScaleTransition(
          scale: _scaleAnimation,
          child: FadeTransition(
            opacity: _fadeAnimation,
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color(0xFF6C63FF),
                    Color(0xFFFF6584),
                  ],
                ),
              ),
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const AppLogo(),
                      const SizedBox(height: 40),
                      SizedBox(
                        height: 180,
                        child: PageView(
                          controller: _pageController,
                          onPageChanged: (index) {
                            setState(() => _currentPage = index);
                          },
                          children: [
                            _buildFeatureCard(
                              icon: Icons.language,
                              title: 'Мультиязычность',
                              description: 'Поддержка 6 языков с автоматическим переводом',
                            ),
                            _buildFeatureCard(
                              icon: Icons.offline_bolt,
                              title: 'Оффлайн режим',
                              description: 'Играйте без интернета с сохранёнными вопросами',
                            ),
                            _buildFeatureCard(
                              icon: Icons.volume_up,
                              title: 'Озвучка',
                              description: 'Текст вопросов озвучивается голосом',
                            ),
                            _buildFeatureCard(
                              icon: Icons.timer,
                              title: 'Режим на время',
                              description: 'Отвечайте на вопросы быстрее для большего количества очков',
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: List.generate(4, (index) {
                          return Container(
                            width: 8,
                            height: 8,
                            margin: const EdgeInsets.symmetric(horizontal: 4),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _currentPage == index
                                  ? Colors.white
                                  : Colors.white.withOpacity(0.5),
                            ),
                          );
                        }),
                      ),
                      const SizedBox(height: 40),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          ElevatedButton(
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (context) => const QuizSetupScreen()),
                              );
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.white,
                              foregroundColor: const Color(0xFF6C63FF),
                              padding: EdgeInsets.symmetric(
                                  horizontal: isSmallScreen ? 24 : 32,
                                  vertical: isSmallScreen ? 12 : 16),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              elevation: 4,
                            ),
                            child: Text(
                              'НАЧАТЬ ИГРУ',
                              style: TextStyle(
                                fontSize: isSmallScreen ? 16 : 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          const SizedBox(width: 16),
                          ElevatedButton(
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (context) => const LearningModeScreen()),
                              );
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.white.withOpacity(0.2),
                              foregroundColor: Colors.white,
                              padding: EdgeInsets.symmetric(
                                  horizontal: isSmallScreen ? 16 : 24,
                                  vertical: isSmallScreen ? 12 : 16),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              elevation: 0,
                            ),
                            child: Text(
                              'ОБУЧЕНИЕ',
                              style: TextStyle(
                                fontSize: isSmallScreen ? 14 : 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      TextButton(
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (context) => const StatsScreen()),
                          );
                        },
                        child: const Text(
                          'Моя статистика',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFeatureCard({
    required IconData icon,
    required String title,
    required String description,
  }) {
    return Card(
      color: Colors.white.withOpacity(0.2),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(icon, size: 40, color: Colors.white),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  Text(
                    description,
                    style: const TextStyle(
                      fontSize: 14,
                      color: Colors.white70,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class QuizSetupScreen extends StatefulWidget {
  const QuizSetupScreen({super.key});

  @override
  State<QuizSetupScreen> createState() => _QuizSetupScreenState();
}

class _QuizSetupScreenState extends State<QuizSetupScreen> {
  String selectedCategory = 'Любая категория';
  String selectedDifficulty = 'Любая';
  String selectedLanguage = 'Русский';
  bool isLoading = false;
  bool isTimeLimited = false;
  bool useHints = true;

  @override
  Widget build(BuildContext context) {
    final quizRepo = RepositoryProvider.of<QuizRepository>(context);
    final audioPlayer = RepositoryProvider.of<AudioPlayer>(context);
    final tts = RepositoryProvider.of<FlutterTts>(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Настройки викторины'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline),
            onPressed: () {
              showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('О режимах'),
                  content: const Text(
                    'Обычный режим: классическая викторина\n'
                    'На время: ограниченное время на ответ\n'
                    'С подсказками: доступны 3 подсказки на вопрос',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('OK'),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            _buildSettingCard(
              title: 'Категория',
              child: DropdownButtonFormField<String>(
                value: selectedCategory,
                items: quizRepo.categories.keys.map((category) {
                  return DropdownMenuItem(
                    value: category,
                    child: Text(category),
                  );
                }).toList(),
                onChanged: (value) {
                  if (value != null) {
                    setState(() => selectedCategory = value);
                  }
                },
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
              ),
            ),
            const SizedBox(height: 20),
            _buildSettingCard(
              title: 'Сложность',
              child: DropdownButtonFormField<String>(
                value: selectedDifficulty,
                items: const ['Любая', 'Легкая', 'Средняя', 'Сложная']
                    .map((difficulty) {
                  return DropdownMenuItem(
                    value: difficulty,
                    child: Text(difficulty),
                  );
                }).toList(),
                onChanged: (value) {
                  if (value != null) {
                    setState(() => selectedDifficulty = value);
                  }
                },
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
              ),
            ),
            const SizedBox(height: 20),
            _buildSettingCard(
              title: 'Язык',
              child: DropdownButtonFormField<String>(
                value: selectedLanguage,
                items: quizRepo.languages.keys.map((language) {
                  return DropdownMenuItem(
                    value: language,
                    child: Text(language),
                  );
                }).toList(),
                onChanged: (value) {
                  if (value != null) {
                    setState(() => selectedLanguage = value);
                  }
                },
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
              ),
            ),
            const SizedBox(height: 20),
            _buildSettingCard(
              title: 'Режим игры',
              child: Column(
                children: [
                  SwitchListTile(
                    title: const Text('Режим на время'),
                    value: isTimeLimited,
                    onChanged: (value) {
                      setState(() => isTimeLimited = value);
                    },
                  ),
                  SwitchListTile(
                    title: const Text('Использовать подсказки'),
                    value: useHints,
                    onChanged: (value) {
                      setState(() => useHints = value);
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 40),
            if (isLoading)
              const CircularProgressIndicator()
            else
              ElevatedButton(
                onPressed: () async {
                  setState(() => isLoading = true);
                  try {
                    final questions = await quizRepo.fetchQuestions(
                      category: selectedCategory,
                      difficulty: selectedDifficulty,
                    );
                    
                    await audioPlayer.play(AssetSource('sounds/start.mp3'));
                    for (var question in questions) {
                      if (selectedLanguage != 'Английский') {
                        await question.translate(
                            quizRepo.languages[selectedLanguage]!);
                      }
                    }
                    
                    if (mounted) {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => QuizScreen(
                            questions: questions,
                            language: selectedLanguage,
                            tts: tts,
                            audioPlayer: audioPlayer,
                            isTimeLimited: isTimeLimited,
                            useHints: useHints,
                          ),
                        ),
                      );
                    }
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Ошибка: $e'),
                          backgroundColor: Colors.red,
                        ),
                      );
                    }
                  } finally {
                    if (mounted) {
                      setState(() => isLoading = false);
                    }
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 32, vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: 4,
                ),
                child: const Text(
                  'НАЧАТЬ ВИКТОРИНУ',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSettingCard({required String title, required Widget child}) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.black54,
              ),
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class QuizScreen extends StatefulWidget {
  final List<QuizQuestion> questions;
  final String language;
  final FlutterTts tts;
  final AudioPlayer audioPlayer;
  final bool isTimeLimited;
  final bool useHints;

  const QuizScreen({
    super.key,
    required this.questions,
    required this.language,
    required this.tts,
    required this.audioPlayer,
    this.isTimeLimited = false,
    this.useHints = true,
  });

  @override
  State<QuizScreen> createState() => _QuizScreenState();
}

class _QuizScreenState extends State<QuizScreen> with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _progressAnimation;
  int currentIndex = 0;
  int score = 0;
  int? selectedAnswer;
  bool isAnswered = false;
  bool showExplanation = false;
  late Timer _timer;
  int _timeLeft = 30;
  List<String> usedHints = [];
  bool isHintUsed = false;
  late ConfettiController _confettiController;

  @override
  void initState() {
    super.initState();
    _confettiController = ConfettiController(duration: const Duration(seconds: 1));
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    _progressAnimation = Tween<double>(
      begin: 0,
      end: 1 / widget.questions.length,
    ).animate(_animationController);
    _animationController.forward();
    _speakQuestion();
    _startTimer();
  }

  @override
  void dispose() {
    _animationController.dispose();
    _timer.cancel();
    widget.tts.stop();
    _confettiController.dispose();
    super.dispose();
  }

  void _startTimer() {
    _timeLeft = widget.questions[currentIndex].timeLimit;
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!widget.isTimeLimited) {
        timer.cancel();
        return;
      }
      
      if (_timeLeft > 0) {
        setState(() => _timeLeft--);
      } else {
        timer.cancel();
        if (!isAnswered) {
          setState(() {
            isAnswered = true;
            selectedAnswer = -1;
          });
        }
      }
    });
  }

  Future<void> _speakQuestion() async {
    final question = widget.questions[currentIndex];
    final text = widget.language == 'Английский' || question.translatedQuestion.isEmpty
        ? question.question
        : question.translatedQuestion;
    await widget.tts.setLanguage(widget.language == 'Английский' ? 'en-US' : 'ru-RU');
    await widget.tts.speak(text);
  }

  void _nextQuestion() {
    _animationController.reset();
    _timer.cancel();
    setState(() {
      currentIndex++;
      selectedAnswer = null;
      isAnswered = false;
      showExplanation = false;
      isHintUsed = false;
      usedHints = [];
      _progressAnimation = Tween<double>(
        begin: 0,
        end: (currentIndex + 1) / widget.questions.length,
      ).animate(_animationController);
    });
    _animationController.forward();
    _speakQuestion();
    _startTimer();
  }

  void _checkAnswer(int index) async {
    if (isAnswered) return;
    
    _timer.cancel();
    
    setState(() {
      selectedAnswer = index;
      isAnswered = true;
      
      int points = 10;
      if (widget.isTimeLimited) {
        final timePercent = _timeLeft / widget.questions[currentIndex].timeLimit;
        points += (points * timePercent).round();
      }
      
      if (index == widget.questions[currentIndex].correctIndex) {
        score += points;
        _confettiController.play();
        widget.audioPlayer.play(AssetSource('sounds/correct.mp3'));
      } else {
        widget.audioPlayer.play(AssetSource('sounds/wrong.mp3'));
      }
    });
  }

  void _useHint() {
    if (!widget.useHints || isHintUsed || widget.questions[currentIndex].hints == null) return;
    
    setState(() {
      if (usedHints.length < widget.questions[currentIndex].hints!.length) {
        usedHints.add(widget.questions[currentIndex].hints![usedHints.length]);
        isHintUsed = true;
      }
    });
  }

  Future<void> _openWikipedia() async {
    final url = widget.questions[currentIndex].wikipediaUrl;
    if (url != null && url.isNotEmpty) {
      if (await canLaunchUrl(Uri.parse(url))) {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => WikipediaPage(url: url, title: widget.questions[currentIndex].question),
          ),
        );
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Не удалось открыть Wikipedia')),
          );
        }
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Информация не найдена')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final question = widget.questions[currentIndex];
    final isLastQuestion = currentIndex == widget.questions.length - 1;
    final remainingHints = widget.useHints && question.hints != null 
        ? question.hints!.length - usedHints.length 
        : 0;

    return Scaffold(
      appBar: AppBar(
        title: AnimatedBuilder(
          animation: _progressAnimation,
          builder: (context, child) {
            return LinearProgressIndicator(
              value: _progressAnimation.value,
              backgroundColor: Colors.grey[200],
              color: Theme.of(context).colorScheme.primary,
              minHeight: 4,
            );
          },
        ),
        actions: [
          if (widget.isTimeLimited)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Row(
                  children: [
                    const Icon(Icons.timer, size: 20),
                    const SizedBox(width: 4),
                    Text(
                      '$_timeLeft',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Text(
                '$score',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                QuestionInfoCard(
                  category: question.category,
                  difficulty: question.difficulty,
                ),
                const SizedBox(height: 20),
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        if (question.imageUrl != null)
                          _buildQuestionImage(question.imageUrl!),
                        QuestionText(text: question.question),
                        const SizedBox(height: 24),
                        ...question.options.asMap().entries.map((entry) {
                          final index = entry.key;
                          final option = entry.value;
                          
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: AnswerButton(
                              text: option,
                              isCorrect: index == question.correctIndex,
                              isSelected: index == selectedAnswer,
                              isAnswered: isAnswered,
                              onPressed: () => _checkAnswer(index),
                            ),
                          );
                        }),
                        if (usedHints.isNotEmpty)
                          _buildHintsCard(usedHints),
                        if (isAnswered && showExplanation && question.explanation != null)
                          _buildExplanationCard(question.explanation!),
                        if (isAnswered)
                          TextButton(
                            onPressed: () {
                              setState(() => showExplanation = !showExplanation);
                            },
                            child: Text(
                              showExplanation ? 'Скрыть объяснение' : 'Показать объяснение',
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (isAnswered)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: ElevatedButton(
                      onPressed: isLastQuestion
                          ? () {
                              widget.audioPlayer.play(AssetSource('sounds/finish.mp3'));
                              Navigator.pushReplacement(
                                context,
                                MaterialPageRoute(
                                  builder: (context) => ResultsScreen(
                                    score: score,
                                    totalQuestions: widget.questions.length,
                                    category: question.category,
                                    difficulty: question.difficulty,
                                  ),
                                ),
                              );
                            }
                          : _nextQuestion,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 32, vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(
                        isLastQuestion ? 'ЗАВЕРШИТЬ' : 'СЛЕДУЮЩИЙ ВОПРОС',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Align(
            alignment: Alignment.topCenter,
            child: ConfettiWidget(
              confettiController: _confettiController,
              blastDirectionality: BlastDirectionality.explosive,
              shouldLoop: false,
              colors: const [
                Colors.green,
                Colors.blue,
                Colors.pink,
                Colors.orange,
                Colors.purple,
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: widget.useHints && remainingHints > 0 && !isAnswered
          ? FloatingActionButton(
              onPressed: _useHint,
              tooltip: 'Подсказка',
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.lightbulb_outline),
                  Text(
                    '$remainingHints',
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
            )
          : null,
    );
  }

  // В классе _QuizScreenState добавил отображение подсказок и картинок
Widget _buildQuestionImage(String imageUrl) {
  return Container(
    height: 180,
    margin: const EdgeInsets.only(bottom: 16),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(12),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withOpacity(0.1),
          blurRadius: 8,
          offset: const Offset(0, 4),
        ),
      ],
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: CachedNetworkImage(
        imageUrl: imageUrl,
        fit: BoxFit.cover,
        width: double.infinity,
        placeholder: (context, url) => const Center(child: CircularProgressIndicator()),
        errorWidget: (context, url, error) => const Icon(Icons.error),
      ),
    ),
  );
}

  Widget _buildExplanationCard(String explanation) {
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      margin: const EdgeInsets.only(bottom: 16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Объяснение:',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              explanation,
              style: const TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _openWikipedia,
              child: const Text('Узнать больше на Wikipedia'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHintsCard(List<String> hints) {
  return Card(
    color: Theme.of(context).colorScheme.secondaryContainer,
    margin: const EdgeInsets.only(bottom: 16),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
    ),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Подсказки:',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 8),
          ...hints.map((hint) => Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text('• $hint'),
          )),
        ],
      ),
    ),
  );
  
}

}

class ResultsScreen extends StatefulWidget {
  final int score;
  final int totalQuestions;
  final String category;
  final String difficulty;

  const ResultsScreen({
    super.key,
    required this.score,
    required this.totalQuestions,
    required this.category,
    required this.difficulty,
  });

  @override
  State<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends State<ResultsScreen> {
  late ConfettiController _confettiController;
  bool _isAchievementUnlocked = false;

  @override
  void initState() {
    super.initState();
    _confettiController = ConfettiController(duration: const Duration(seconds: 3));
    _saveGameResult();
    _checkAchievement();
  }

  @override
  void dispose() {
    _confettiController.dispose();
    super.dispose();
  }

  Future<void> _saveGameResult() async {
    final quizRepo = RepositoryProvider.of<QuizRepository>(context);
    await quizRepo.saveGameResult(
      score: widget.score,
      totalQuestions: widget.totalQuestions,
      category: widget.category,
      difficulty: widget.difficulty,
    );
  }

  Future<void> _checkAchievement() async {
    final percentage = (widget.score / (widget.totalQuestions * 10)) * 100;
    if (percentage >= 90) {
      setState(() => _isAchievementUnlocked = true);
      _confettiController.play();
    }
  }

  @override
  Widget build(BuildContext context) {
    final percentage = (widget.score / (widget.totalQuestions * 10)) * 100;
    String resultText;
    String animationAsset;
    Color resultColor;

    if (percentage >= 80) {
      resultText = 'Превосходно! 🎉';
      animationAsset = 'assets/animations/success.json';
      resultColor = Colors.green;
    } else if (percentage >= 50) {
      resultText = 'Хороший результат! 👍';
      animationAsset = 'assets/animations/good.json';
      resultColor = Colors.orange;
    } else {
      resultText = 'Попробуйте ещё раз! 💪';
      animationAsset = 'assets/animations/try_again.json';
      resultColor = Colors.red;
    }

    return Scaffold(
      body: Stack(
        children: [
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Lottie.asset(
                    animationAsset,
                    width: 200,
                    height: 200,
                    fit: BoxFit.contain,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    resultText,
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: resultColor,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Вы набрали ${widget.score} из ${widget.totalQuestions * 10} баллов',
                    style: const TextStyle(
                      fontSize: 20,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Категория: ${widget.category}',
                    style: const TextStyle(
                      fontSize: 16,
                      color: Colors.grey,
                    ),
                  ),
                  const SizedBox(height: 24),
                  CircularPercentIndicator(
                    radius: 80,
                    lineWidth: 12,
                    percent: percentage / 100,
                    center: Text(
                      '${percentage.toStringAsFixed(1)}%',
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    progressColor: Theme.of(context).colorScheme.primary,
                    backgroundColor: Colors.grey,
                    circularStrokeCap: CircularStrokeCap.round,
                    animation: true,
                    animationDuration: 1500,
                  ),
                  const SizedBox(height: 40),
                  if (_isAchievementUnlocked)
                    Card(
                      color: Colors.amber[100],
                      child: const Padding(
                        padding: EdgeInsets.all(16),
                        child: Row(
                          children: [
                            Icon(Icons.star, color: Colors.amber),
                            SizedBox(width: 8),
                            Text('Новое достижение разблокировано!'),
                          ],
                        ),
                      ),
                    ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ElevatedButton(
                        onPressed: () {
                          Navigator.pushAndRemoveUntil(
                            context,
                            MaterialPageRoute(builder: (context) => const HomeScreen()),
                            (route) => false,
                          );
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Theme.of(context).colorScheme.primary,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: const Text('Главная'),
                      ),
                      const SizedBox(width: 16),
                      ElevatedButton(
                        onPressed: () {
                          Navigator.pushReplacement(
                            context,
                            MaterialPageRoute(
                              builder: (context) => const QuizSetupScreen(),
                            ),
                          );
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Theme.of(context).colorScheme.secondary,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: const Text('Ещё раз'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton(
                    onPressed: () {
                      Share.share(
                        'Я набрал ${widget.score} из ${widget.totalQuestions * 10} баллов в викторине по категории "${widget.category}"! Попробуй и ты!',
                      );
                    },
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      side: BorderSide(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    child: const Text('Поделиться результатом'),
                  ),
                  const SizedBox(height: 16),
                  TextButton(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => StatsScreen(),
                        ),
                      );
                    },
                    child: const Text('Посмотреть статистику'),
                  ),
                ],
              ),
            ),
          ),
          Align(
            alignment: Alignment.topCenter,
            child: ConfettiWidget(
              confettiController: _confettiController,
              blastDirectionality: BlastDirectionality.explosive,
              shouldLoop: false,
              colors: const [
                Colors.green,
                Colors.blue,
                Colors.pink,
                Colors.orange,
                Colors.purple,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class LearningModeScreen extends StatefulWidget {
  const LearningModeScreen({super.key});

  @override
  State<LearningModeScreen> createState() => _LearningModeScreenState();
}

class _LearningModeScreenState extends State<LearningModeScreen> {
  final List<Map<String, dynamic>> learningTopics = [
    {
      'title': 'Исторические факты',
      'icon': Icons.history,
      'color': Colors.blue,
      'questions': [
        {
          'question': 'В каком году началась Вторая мировая война?',
          'answer': '1939',
          'explanation': 'Вторая мировая война началась 1 сентября 1939 года с нападения Германии на Польшу.',
        },
        {
          'question': 'Кто был первым президентом США?',
          'answer': 'Джордж Вашингтон',
          'explanation': 'Джордж Вашингтон стал первым президентом США в 1789 году.',
        },
      ],
    },
    {
      'title': 'Научные открытия',
      'icon': Icons.science,
      'color': Colors.green,
      'questions': [
        {
          'question': 'Кто открыл закон всемирного тяготения?',
          'answer': 'Исаак Ньютон',
          'explanation': 'Исаак Ньютон сформулировал закон всемирного тяготения в 1687 году.',
        },
        {
          'question': 'Какой ученый открыл пенициллин?',
          'answer': 'Александр Флеминг',
          'explanation': 'Александр Флеминг случайно открыл пенициллин в 1928 году.',
        },
      ],
    },
    {
      'title': 'География',
      'icon': Icons.map,
      'color': Colors.orange,
      'questions': [
        {
          'question': 'Какая самая длинная река в мире?',
          'answer': 'Нил',
          'explanation': 'Река Нил имеет длину около 6650 км, что делает её самой длинной рекой в мире.',
        },
        {
          'question': 'В какой стране находится Эйфелева башня?',
          'answer': 'Франция',
          'explanation': 'Эйфелева башня расположена в Париже, столице Франции.',
        },
      ],
    },
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Режим обучения'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: learningTopics.length,
        itemBuilder: (context, index) {
          final topic = learningTopics[index];
          return Card(
            margin: const EdgeInsets.only(bottom: 16),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => TopicDetailScreen(topic: topic),
                  ),
                );
              },
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: topic['color'].withOpacity(0.2),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        topic['icon'] as IconData,
                        color: topic['color'] as Color,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            topic['title'] as String,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            '${(topic['questions'] as List).length} вопросов',
                            style: const TextStyle(
                              color: Colors.grey,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.chevron_right),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class TopicDetailScreen extends StatefulWidget {
  final Map<String, dynamic> topic;

  const TopicDetailScreen({super.key, required this.topic});

  @override
  State<TopicDetailScreen> createState() => _TopicDetailScreenState();
}

class _TopicDetailScreenState extends State<TopicDetailScreen> {
  int currentQuestionIndex = 0;
  bool showAnswer = false;

  @override
  Widget build(BuildContext context) {
    final questions = widget.topic['questions'] as List<dynamic>;
    final currentQuestion = questions[currentQuestionIndex] as Map<String, dynamic>;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.topic['title'] as String),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Card(
              elevation: 2,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Text(
                      currentQuestion['question'] as String,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    if (showAnswer)
                      Column(
                        children: [
                          Text(
                            'Ответ: ${currentQuestion['answer']}',
                            style: const TextStyle(
                              fontSize: 18,
                              color: Colors.green,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            currentQuestion['explanation'] as String,
                            style: const TextStyle(fontSize: 16),
                          ),
                        ],
                      )
                    else
                      ElevatedButton(
                        onPressed: () {
                          setState(() => showAnswer = true);
                        },
                        child: const Text('Показать ответ'),
                      ),
                  ],
                ),
              ),
            ),
            const Spacer(),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                ElevatedButton(
                  onPressed: currentQuestionIndex > 0
                      ? () {
                          setState(() {
                            currentQuestionIndex--;
                            showAnswer = false;
                          });
                        }
                      : null,
                  child: const Text('Назад'),
                ),
                Text(
                  '${currentQuestionIndex + 1}/${questions.length}',
                  style: const TextStyle(fontSize: 16),
                ),
                ElevatedButton(
                  onPressed: currentQuestionIndex < questions.length - 1
                      ? () {
                          setState(() {
                            currentQuestionIndex++;
                            showAnswer = false;
                          });
                        }
                      : null,
                  child: const Text('Далее'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class StatsScreen extends StatefulWidget {
  const StatsScreen({super.key});

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  late Box statsBox;

  @override
  void initState() {
    super.initState();
    statsBox = Hive.box('statsBox');
  }

@override
Widget build(BuildContext context) {
  final totalGames = statsBox.get('totalGames', defaultValue: 0) as int;
  final totalCorrect = statsBox.get('totalCorrect', defaultValue: 0) as int;
  final totalQuestions = totalGames * 10;
  final totalPoints = statsBox.get('totalPoints', defaultValue: 0) as int;
  
  // Получаем историю игр и безопасно приводим к нужному типу
final gameHistory = (statsBox.get('gameHistory', defaultValue: <Map<String, dynamic>>[]) as List)
    .map((item) => Map<String, dynamic>.from(item as Map))
    .toList();

  return Scaffold(
    appBar: AppBar(
      title: const Text('Моя статистика'),
    ),
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Общая статистика',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _buildStatItem(
                    value: totalGames.toString(),
                    label: 'Игр',
                  ),
                  _buildStatItem(
                    value: '$totalCorrect/$totalQuestions',
                    label: 'Правильных ответов',
                  ),
                  _buildStatItem(
                    value: totalPoints.toString(),
                    label: 'Очков',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'История игр',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          if (gameHistory.isEmpty)
            const Center(
              child: Text('Нет данных об играх'),
            )
          else
            Column(
              children: gameHistory.reversed.map((game) {
                return _buildGameHistoryCard(game);
              }).toList(),
            ),
        ],
      ),
    ),
  );
}

  Widget _buildStatItem({required String value, required String label}) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(
          label,
          style: const TextStyle(
            color: Colors.grey,
          ),
        ),
      ],
    );
  }

  Widget _buildGameHistoryCard(Map<String, dynamic> game) {
    final date = DateTime.parse(game['date'] as String);
    final percentage = game['percentage'] as double;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${date.day}.${date.month}.${date.year}',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  '${game['score']}/${game['total'] * 10} очков',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Категория: ${game['category']}',
              style: const TextStyle(
                color: Colors.grey,
              ),
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: percentage / 100,
              backgroundColor: Colors.grey[300],
              color: _getProgressColor(percentage),
              minHeight: 8,
            ),
            const SizedBox(height: 4),
            Text(
              '${percentage.toStringAsFixed(1)}%',
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontSize: 12,
                color: Colors.grey,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _getProgressColor(double percentage) {
    if (percentage >= 80) return Colors.green;
    if (percentage >= 50) return Colors.orange;
    return Colors.red;
  }
}

class AppLogo extends StatelessWidget {
  const AppLogo({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.1),
                blurRadius: 10,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: const Icon(
            Icons.quiz,
            size: 60,
            color: Color(0xFF6C63FF),
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          'Умная викторина PRO',
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
      ],
    );
  }
}

class QuestionInfoCard extends StatelessWidget {
  final String category;
  final String difficulty;

  const QuestionInfoCard({
    super.key,
    required this.category,
    required this.difficulty,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _buildInfoItem(
              icon: Icons.category,
              text: category,
              color: Theme.of(context).colorScheme.primary,
            ),
            _buildInfoItem(
              icon: Icons.star,
              text: difficulty == 'easy' ? 'Легко' :
                    difficulty == 'medium' ? 'Средне' : 'Сложно',
              color: difficulty == 'easy' ? Colors.green :
                    difficulty == 'medium' ? Colors.orange : Colors.red,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoItem({
    required IconData icon,
    required String text,
    required Color color,
  }) {
    return Row(
      children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(width: 8),
        Text(
          text,
          style: TextStyle(
            fontSize: 14,
            color: color,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }
}

class QuestionText extends StatelessWidget {
  final String text;

  const QuestionText({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.bold,
      ),
      textAlign: TextAlign.center,
    );
  }
}

class AnswerButton extends StatelessWidget {
  final String text;
  final bool isCorrect;
  final bool isSelected;
  final bool isAnswered;
  final VoidCallback onPressed;

  const AnswerButton({
    super.key,
    required this.text,
    required this.isCorrect,
    required this.isSelected,
    required this.isAnswered,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    Color getBackgroundColor() {
      if (!isAnswered) return Theme.of(context).colorScheme.primaryContainer;
      if (isCorrect) return Colors.green;
      if (isSelected) return Colors.red;
      return Colors.grey.shade300;
    }

    Color getTextColor() {
      if (!isAnswered) return Theme.of(context).colorScheme.onPrimaryContainer;
      if (isCorrect || isSelected) return Colors.white;
      return Colors.black;
    }

    IconData? getIcon() {
      if (!isAnswered) return null;
      if (isCorrect) return Icons.check;
      if (isSelected) return Icons.close;
      return null;
    }

    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: getBackgroundColor(),
        foregroundColor: getTextColor(),
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        elevation: 2,
      ),
      child: Row(
        children: [
          if (getIcon() != null) Icon(getIcon(), size: 20),
          if (getIcon() != null) const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 16,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class WikipediaPage extends StatelessWidget {
  final String url;
  final String title;

  const WikipediaPage({super.key, required this.url, required this.title});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
      ),
      body: WebViewWidget(
        controller: WebViewController()
          ..loadRequest(Uri.parse(url))
          ..setJavaScriptMode(JavaScriptMode.unrestricted),
      ),
    );
  }
}