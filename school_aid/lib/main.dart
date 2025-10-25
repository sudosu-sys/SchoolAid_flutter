// lib/main.dart
// Now supports:
// 1) Create User         -> POST /api/users
// 2) Save Progress       -> POST /api/progress (user dropdown, lesson, score)
// 3) Show Progress       -> GET  /api/progress (all) or /api/progress?user_id=<id>
// 4) Offline mode        -> Local cache (Hive) + Outbox queue + Auto-sync when online
//
// Assumes a simple GET /api/users that returns:
//   [ {"id":1,"name":"Amina"}, {"id":2,"name":"Bilal"} ]
//
// Run with a custom base URL if needed:
// flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8000
//
// ADD THESE TO pubspec.yaml:
// dependencies:
//   dio: ^5.7.0
//   hive: ^2.2.3
//   hive_flutter: ^1.1.0
//   connectivity_plus: ^6.x.x

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  await Hive.openBox('users');     // key: id (int), value: Map
  await Hive.openBox('progress');  // key: id (int), value: Map
  await Hive.openBox('outbox');    // value: Map {type, payload, tempId}
  runApp(const App());
}

/// Reads API root from --dart-define (fallback to localhost).
/// Example: flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8000
String initialBaseUrl = const String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://127.0.0.1:8000',
);

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Users & Progress',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.teal,
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
          ),
          filled: true,
          contentPadding: EdgeInsets.symmetric(vertical: 16, horizontal: 16),
        ),
        cardTheme: CardThemeData(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          elevation: 0,
          margin: EdgeInsets.zero,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.symmetric(vertical: 14),
            textStyle: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ),
      home: HomeScreen(initialBaseUrl: initialBaseUrl),
    );
  }
}

/* ----------------------------- Offline Repo ----------------------------- */

class OfflineRepo {
  OfflineRepo(this.dio);
  final Dio dio;

  Box<dynamic> get _users => Hive.box('users');
  Box<dynamic> get _progress => Hive.box('progress');
  Box<dynamic> get _outbox => Hive.box('outbox');

  /* ---- Cache reads ---- */
  List<Map<String, dynamic>> getCachedUsers() =>
      _users.values.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
        ..sort((a, b) => (a['id'] as int).compareTo(b['id'] as int));

  List<Map<String, dynamic>> getCachedProgress({int? userId}) {
    final items = _progress.values.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    if (userId == null) return items..sort(_progressSorter);
    return items.where((p) {
      final u = p['user'] as Map?;
      final fallbackUserId = p['user_id'];
      return u?['id'] == userId || fallbackUserId == userId;
    }).toList()
      ..sort(_progressSorter);
  }

  int _progressSorter(Map<String, dynamic> a, Map<String, dynamic> b) {
    final da = DateTime.tryParse(a['created_at']?.toString() ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
    final db = DateTime.tryParse(b['created_at']?.toString() ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
    return db.compareTo(da);
  }

  /* ---- Server refresh (replace cache) ---- */
  Future<void> refreshUsersFromServer() async {
    final res = await dio.get('/api/users');
    if (res.data is List) {
      await _users.clear();
      for (final m in (res.data as List)) {
        if (m is Map) {
          final u = Map<String, dynamic>.from(m)..['pending'] = false;
          await _users.put(u['id'], u);
        }
      }
    }
  }

  Future<void> refreshProgressFromServer({int? userId}) async {
    final qp = userId == null ? null : {'user_id': userId};
    final res = await dio.get('/api/progress', queryParameters: qp);
    if (res.data is List) {
      if (userId == null) {
        await _progress.clear();
      } else {
        // remove only entries belonging to that user
        final keysToDelete = _progress.keys.where((k) {
          final v = _progress.get(k);
          if (v is! Map) return false;
          final u = v['user'];
          final fallback = v['user_id'];
          return (u is Map && u['id'] == userId) || fallback == userId;
        }).toList();
        for (final k in keysToDelete) {
          await _progress.delete(k);
        }
      }
      for (final m in (res.data as List)) {
        if (m is Map) {
          final p = Map<String, dynamic>.from(m)..['pending'] = false;
          await _progress.put(p['id'], p);
        }
      }
    }
  }

  /* ---- Writes (online direct, offline queued w/ optimistic cache) ---- */
  Future<Map<String, dynamic>> createUser({
    required String name,
    required bool online,
  }) async {
    if (online) {
      final res = await dio.post('/api/users', data: {'name': name});
      final u = Map<String, dynamic>.from(res.data)..['pending'] = false;
      await _users.put(u['id'], u);
      return u;
    } else {
      final tempId = -DateTime.now().millisecondsSinceEpoch;
      final u = {
        'id': tempId,
        'name': name,
        'created_at': DateTime.now().toIso8601String(),
        'pending': true,
      };
      await _users.put(tempId, u);
      await _outbox.add({
        'type': 'create_user',
        'payload': {'name': name},
        'tempId': tempId,
      });
      return Map<String, dynamic>.from(u);
    }
  }

  Future<Map<String, dynamic>> saveProgress({
    required int userId,
    required String lesson,
    required int score,
    required bool online,
  }) async {
    if (online) {
      final res = await dio.post('/api/progress',
          data: {'user_id': userId, 'lesson': lesson, 'score': score});
      final p = Map<String, dynamic>.from(res.data)..['pending'] = false;
      await _progress.put(p['id'], p);
      return p;
    } else {
      final tempId = -DateTime.now().microsecondsSinceEpoch;
      final p = {
        'id': tempId,
        'user_id': userId,
        'user': null,
        'lesson': lesson,
        'score': score,
        'created_at': DateTime.now().toIso8601String(),
        'pending': true,
      };
      await _progress.put(tempId, p);
      await _outbox.add({
        'type': 'save_progress',
        'payload': {'user_id': userId, 'lesson': lesson, 'score': score},
        'tempId': tempId,
      });
      return Map<String, dynamic>.from(p);
    }
  }

  /* ---- Sync queued writes when online ---- */
  Future<void> syncOutbox() async {
    // Process FIFO: always inspect and delete the first key
    while (_outbox.isNotEmpty) {
      final key = _outbox.keyAt(0);
      final entry = _outbox.get(key);
      if (entry is! Map) {
        await _outbox.delete(key);
        continue;
      }
      final type = entry['type'];
      final payload = Map<String, dynamic>.from(entry['payload'] ?? {});
      final tempId = entry['tempId'];
      try {
        if (type == 'create_user') {
          final res = await dio.post('/api/users', data: payload);
          final real = Map<String, dynamic>.from(res.data)..['pending'] = false;
          await _users.delete(tempId);
          await _users.put(real['id'], real);

          // Patch any queued progress referencing this temp user id
          final keys = _outbox.keys.toList();
          for (final k in keys) {
            final v = _outbox.get(k);
            if (v is Map && v['type'] == 'save_progress' && v['payload']?['user_id'] == tempId) {
              v['payload']['user_id'] = real['id'];
              await _outbox.put(k, v);
            }
          }
        } else if (type == 'save_progress') {
          final res = await dio.post('/api/progress', data: payload);
          final real = Map<String, dynamic>.from(res.data)..['pending'] = false;
          await _progress.delete(tempId);
          await _progress.put(real['id'], real);
        }
        // Remove processed item
        await _outbox.delete(key);
      } catch (_) {
        // Stop on first failure; will retry next time we are online
        break;
      }
    }
  }
}

/* ----------------------------- UI Screen ----------------------------- */

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.initialBaseUrl});
  final String initialBaseUrl;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {

  late final Dio _dio;
  late String _baseUrl;
  late final OfflineRepo _repo;

  // Connectivity (v6 emits Stream<List<ConnectivityResult>>)
  late final Connectivity _connectivity;
  StreamSubscription<List<ConnectivityResult>>? _connSub;
  bool _online = true;

  // Tabs
  late final TabController _tabController;

  // Create User
  final _createFormKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  bool _creating = false;
  Map<String, dynamic>? _createdUser;

  // Save Progress
  final _progressFormKey = GlobalKey<FormState>();
  List<Map<String, dynamic>> _users = [];
  int? _selectedUserId;
  final _lessonCtrl = TextEditingController();
  final _scoreCtrl = TextEditingController();
  bool _loadingUsers = false;
  bool _savingProgress = false;
  Map<String, dynamic>? _savedProgress;

  // Show Progress
  bool _loadingProgress = false;
  List<Map<String, dynamic>> _progress = [];
  int? _filterUserId; // null = all users


@override
void initState() {
  super.initState();

  // App lifecycle observer (to trigger sync when app resumes)
  WidgetsBinding.instance.addObserver(this);

  _baseUrl = widget.initialBaseUrl;
  _dio = Dio(
    BaseOptions(
      baseUrl: _baseUrl,
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 15),
      headers: {'Content-Type': 'application/json'},
    ),
  );
  _repo = OfflineRepo(_dio);
  _tabController = TabController(length: 3, vsync: this);

  // Prime UI from cache immediately (so data is visible even if offline)
  _users = _repo.getCachedUsers();
  _progress = _repo.getCachedProgress();

  // Connectivity watch + initial status
  _connectivity = Connectivity();

  _connSub = _connectivity.onConnectivityChanged.listen((results) async {
    // results is List<ConnectivityResult>
    final wasOnline = _online;
    _online = !results.contains(ConnectivityResult.none);

    if (_online && !wasOnline) {
      // Became online → push outbox + refresh caches
      await _maybeSyncAndRefresh();
      _toast('Back online. Synced.');
      _startOnlineSyncTicker();
    } else if (!_online && wasOnline) {
      _toast('You are offline. Changes will be queued.');
      _stopOnlineSyncTicker();
    }
    if (mounted) setState(() {}); // repaint banner
  });

  // Bootstrap once at startup (handles both online/offline)
  _bootstrap();
}

Future<void> _bootstrap() async {
  try {
    // Determine initial connectivity once
    final status = await _connectivity.checkConnectivity();
    _online = !status.contains(ConnectivityResult.none);

    if (_online) {
      // If online on launch, first push any queued writes from previous sessions,
      // then refresh caches from server.
      await _maybeSyncAndRefresh();
      _startOnlineSyncTicker();
    } else {
      // If offline on launch, we still show cached data (already primed in initState).
      // Nothing else to do here.
    }
    if (mounted) {
      setState(() {
        // Ensure UI reflects whatever state we have now.
        _users = _repo.getCachedUsers();
        _progress = _repo.getCachedProgress(userId: _filterUserId);
      });
    }
  } catch (_) {
    // Swallow bootstrap issues; cached data is already visible.
  }
}

/// Attempt to sync any queued writes, then refresh users/progress from server,
/// and finally update the local cache-backed UI.
Future<void> _maybeSyncAndRefresh() async {
  try {
    // Push queued writes (survives restarts thanks to Hive)
    await _repo.syncOutbox();

    // Refresh both resources from server
    await _repo.refreshUsersFromServer();
    await _repo.refreshProgressFromServer(userId: _filterUserId);

    if (mounted) {
      setState(() {
        _users = _repo.getCachedUsers();
        _progress = _repo.getCachedProgress(userId: _filterUserId);
      });
    }
  } catch (_) {
    // If sync or refresh fails (server down, etc.), we keep showing cached data.
  }
}

/// Periodic retry while online, in case a prior sync failed transiently.
Timer? _syncTimer;

void _startOnlineSyncTicker() {
  _stopOnlineSyncTicker();
  // Retry every 30s while online; stops automatically when offline.
  _syncTimer = Timer.periodic(const Duration(seconds: 30), (t) async {
    if (!_online) return;
    await _repo.syncOutbox();
    // Lightweight refresh only if there was pending data or just to keep cache fresh.
    await _repo.refreshUsersFromServer();
    await _repo.refreshProgressFromServer(userId: _filterUserId);
    if (mounted) {
      setState(() {
        _users = _repo.getCachedUsers();
        _progress = _repo.getCachedProgress(userId: _filterUserId);
      });
    }
  });
}

void _stopOnlineSyncTicker() {
  _syncTimer?.cancel();
  _syncTimer = null;
}

/// Resume hook: when the app is brought back to foreground, try syncing again.
@override
void didChangeAppLifecycleState(AppLifecycleState state) async {
  if (state == AppLifecycleState.resumed) {
    try {
      final status = await _connectivity.checkConnectivity();
      final nowOnline = !status.contains(ConnectivityResult.none);
      if (nowOnline) {
        await _maybeSyncAndRefresh();
        _startOnlineSyncTicker();
      }
    } catch (_) {}
  }
}



  @override
void dispose() {
  _connSub?.cancel();
  _stopOnlineSyncTicker();
  WidgetsBinding.instance.removeObserver(this);
  _tabController.dispose();
  _nameCtrl.dispose();
  _lessonCtrl.dispose();
  _scoreCtrl.dispose();
  super.dispose();
}


  // --------- Helpers ---------
  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        margin: const EdgeInsets.all(12),
      ),
    );
  }

  Future<void> _changeBaseUrlDialog() async {
    final ctrl = TextEditingController(text: _baseUrl);
    final form = GlobalKey<FormState>();
    final newUrl = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Set API Base URL'),
        content: Form(
          key: form,
          child: TextFormField(
            controller: ctrl,
            decoration: const InputDecoration(
              labelText: 'Base URL',
              hintText: 'e.g. http://10.0.2.2:8000',
              border: OutlineInputBorder(),
            ),
            validator: (v) {
              final val = (v ?? '').trim();
              if (val.isEmpty) return 'URL required';
              if (!val.startsWith('http://') && !val.startsWith('https://')) {
                return 'Must start with http:// or https://';
              }
              return null;
            },
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (form.currentState?.validate() ?? false) {
                Navigator.pop(ctx, ctrl.text.trim().replaceAll(RegExp(r'/$'), ''));
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (newUrl != null && newUrl != _baseUrl) {
      setState(() {
        _baseUrl = newUrl;
        _dio.options.baseUrl = _baseUrl;
        _createdUser = null;
        _savedProgress = null;
        _progress = [];
        _users = [];
        _selectedUserId = null;
        _filterUserId = null;
      });
      _toast('API base set to $_baseUrl');

      // Reload lists for new base (respecting offline)
      await _fetchUsers();
      await _fetchProgress();
    }
  }

  // --------- Actions using OfflineRepo ---------
  Future<void> _createUser() async {
    if (!(_createFormKey.currentState?.validate() ?? false)) return;

    setState(() {
      _creating = true;
      _createdUser = null;
    });

    try {
      final u = await _repo.createUser(
        name: _nameCtrl.text.trim(),
        online: _online,
      );
      setState(() {
        _createdUser = u;
        _users = _repo.getCachedUsers();
      });

      if (_online) {
        await _repo.refreshUsersFromServer();
        setState(() => _users = _repo.getCachedUsers());
      }

      _nameCtrl.clear();
      _toast(_online ? 'User created' : 'User cached (offline)');
    } catch (e) {
      _toast('Failed to create user: $e');
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _fetchUsers() async {
    setState(() {
      _loadingUsers = true;
      _users = _repo.getCachedUsers();
    });

    if (_online) {
      try {
        await _repo.refreshUsersFromServer();
        setState(() => _users = _repo.getCachedUsers());
      } catch (e) {
        _toast('Failed to refresh users: $e');
      }
    }

    if (mounted) setState(() => _loadingUsers = false);
  }

  Future<void> _saveProgress() async {
    if (!(_progressFormKey.currentState?.validate() ?? false)) return;
    if (_selectedUserId == null) {
      _toast('Please select a user');
      return;
    }

    setState(() {
      _savingProgress = true;
      _savedProgress = null;
    });

    try {
      final p = await _repo.saveProgress(
        userId: _selectedUserId!,
        lesson: _lessonCtrl.text.trim(),
        score: int.parse(_scoreCtrl.text.trim()),
        online: _online,
      );
      setState(() {
        _savedProgress = p;
        _progress = _repo.getCachedProgress(userId: _filterUserId);
      });

      if (_online) {
        await _repo.refreshProgressFromServer(userId: _filterUserId);
        setState(() => _progress = _repo.getCachedProgress(userId: _filterUserId));
      }

      _lessonCtrl.clear();
      _scoreCtrl.clear();
      _toast(_online ? 'Progress saved' : 'Progress cached (offline)');
    } catch (e) {
      _toast('Failed to save progress: $e');
    } finally {
      if (mounted) setState(() => _savingProgress = false);
    }
  }

  Future<void> _fetchProgress() async {
    setState(() {
      _loadingProgress = true;
      _progress = _repo.getCachedProgress(userId: _filterUserId);
    });

    if (_online) {
      try {
        await _repo.refreshProgressFromServer(userId: _filterUserId);
        setState(() => _progress = _repo.getCachedProgress(userId: _filterUserId));
      } catch (e) {
        _toast('Failed to refresh progress: $e');
      }
    }

    if (mounted) setState(() => _loadingProgress = false);
  }

  // --------- UI ---------
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Users & Progress',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: 'Set API Base URL',
            onPressed: _changeBaseUrlDialog,
            icon: const Icon(Icons.link),
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.person_add_alt), text: 'Create User'),
            Tab(icon: Icon(Icons.school), text: 'Save Progress'),
            Tab(icon: Icon(Icons.list_alt), text: 'Show Progress'),
          ],
        ),
      ),
      bottomNavigationBar: Container(
        padding: const EdgeInsets.all(8),
        color: _online
            ? theme.colorScheme.surfaceContainerLow
            : theme.colorScheme.errorContainer,
        child: Text(
          _online
              ? 'API Base: $_baseUrl'
              : 'Offline — changes will sync when online',
          textAlign: TextAlign.center,
          style: theme.textTheme.labelSmall?.copyWith(
            color: _online
                ? theme.colorScheme.onSurfaceVariant
                : theme.colorScheme.onErrorContainer,
          ),
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildCreateUserCard(context),
          _buildSaveProgressCard(context),
          _buildShowProgressCard(context),
        ],
      ),
    );
  }

  Widget _buildCreateUserCard(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  color: theme.colorScheme.surfaceContainerHigh,
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Form(
                      key: _createFormKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.person_add, color: theme.colorScheme.primary),
                              const SizedBox(width: 8),
                              Text('New User',
                                  style: theme.textTheme.titleLarge?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  )),
                            ],
                          ),
                          const Divider(height: 24),
                          TextFormField(
                            controller: _nameCtrl,
                            textInputAction: TextInputAction.done,
                            decoration: const InputDecoration(
                              labelText: 'Full Name',
                              hintText: 'e.g. Amina',
                              helperText: '1–50 characters',
                              prefixIcon: Icon(Icons.badge),
                            ),
                            maxLength: 50,
                            onFieldSubmitted: (_) => _creating ? null : _createUser(),
                            validator: (value) {
                              final v = (value ?? '').trim();
                              if (v.isEmpty) return 'Please enter a name';
                              if (v.length > 50) return 'Name is too long';
                              return null;
                            },
                          ),
                          const SizedBox(height: 16),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                              onPressed: _creating ? null : _createUser,
                              icon: _creating
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                    )
                                  : const Icon(Icons.check),
                              label: Text(_creating ? 'Creating…' : 'Create User'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                if (_createdUser != null)
                  Card(
                    color: theme.colorScheme.surfaceContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Created User Result',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w600)),
                          const SizedBox(height: 8),
                          SelectableText(
                            _prettyMap(_createdUser!),
                            style: const TextStyle(fontFamily: 'monospace'),
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 20),
                Text(
                  'Tip: Android emulator uses 10.0.2.2 for localhost.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSaveProgressCard(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  color: theme.colorScheme.surfaceContainerHigh,
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Form(
                      key: _progressFormKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.school, color: theme.colorScheme.primary),
                              const SizedBox(width: 8),
                              Text('Save Progress',
                                  style: theme.textTheme.titleLarge?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  )),
                              const Spacer(),
                              IconButton(
                                tooltip: 'Refresh users',
                                onPressed: _loadingUsers ? null : _fetchUsers,
                                icon: _loadingUsers
                                    ? SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: theme.colorScheme.primary,
                                        ),
                                      )
                                    : const Icon(Icons.refresh),
                              ),
                            ],
                          ),
                          const Divider(height: 24),
                          InputDecorator(
                            decoration: const InputDecoration(
                              labelText: 'User',
                              prefixIcon: Icon(Icons.person),
                            ).copyWith(
                              border: const OutlineInputBorder(
                                borderRadius: BorderRadius.all(Radius.circular(12)),
                              ),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<int>(
                                isExpanded: true,
                                value: _selectedUserId,
                                hint: const Text('Select a user'),
                                items: _users
                                    .map((u) => DropdownMenuItem<int>(
                                          value: u['id'] as int,
                                          child: Text('${u['name']} (id: ${u['id']})'),
                                        ))
                                    .toList(),
                                onChanged: (val) => setState(() => _selectedUserId = val),
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          TextFormField(
                            controller: _lessonCtrl,
                            textInputAction: TextInputAction.next,
                            decoration: const InputDecoration(
                              labelText: 'Lesson Name',
                              hintText: 'e.g. Math 1',
                              prefixIcon: Icon(Icons.menu_book_outlined),
                            ),
                            maxLength: 120,
                            validator: (v) {
                              final val = (v ?? '').trim();
                              if (val.isEmpty) return 'Lesson is required';
                              if (val.length > 120) return 'Lesson is too long';
                              return null;
                            },
                          ),
                          const SizedBox(height: 16),
                          TextFormField(
                            controller: _scoreCtrl,
                            keyboardType: TextInputType.number,
                            textInputAction: TextInputAction.done,
                            decoration: const InputDecoration(
                              labelText: 'Score',
                              hintText: '0–100',
                              prefixIcon: Icon(Icons.percent),
                            ),
                            validator: (v) {
                              final raw = (v ?? '').trim();
                              if (raw.isEmpty) return 'Score is required';
                              final parsed = int.tryParse(raw);
                              if (parsed == null) return 'Score must be a number';
                              if (parsed < 0 || parsed > 100) return 'Score must be between 0 and 100';
                              return null;
                            },
                            onFieldSubmitted: (_) => _savingProgress ? null : _saveProgress(),
                          ),
                          const SizedBox(height: 20),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                              onPressed: _savingProgress ? null : _saveProgress,
                              icon: _savingProgress
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                    )
                                  : const Icon(Icons.save_alt),
                              label: Text(_savingProgress ? 'Saving…' : 'Save Progress'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                if (_savedProgress != null)
                  Card(
                    color: theme.colorScheme.surfaceContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Saved Progress Result',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w600)),
                          const SizedBox(height: 8),
                          SelectableText(
                            _prettyMap(_savedProgress!),
                            style: const TextStyle(fontFamily: 'monospace'),
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _users.isEmpty
                        ? 'Hint: tap the refresh icon to load users.'
                        : 'Loaded ${_users.length} user(s).',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildShowProgressCard(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              Card(
                color: theme.colorScheme.surfaceContainerHigh,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Icon(Icons.filter_list, color: theme.colorScheme.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: InputDecorator(
                          decoration: const InputDecoration(
                            labelText: 'Filter by User (optional)',
                          ).copyWith(
                            border: const OutlineInputBorder(
                              borderRadius: BorderRadius.all(Radius.circular(12)),
                            ),
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<int?>(
                              isExpanded: true,
                              value: _filterUserId,
                              items: [
                                const DropdownMenuItem<int?>(
                                  value: null,
                                  child: Text('All users'),
                                ),
                                ..._users.map((u) => DropdownMenuItem<int?>(
                                      value: u['id'] as int,
                                      child: Text('${u['name']} (id: ${u['id']})'),
                                    )),
                              ],
                              onChanged: (val) => setState(() => _filterUserId = val),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      FilledButton.icon(
                        onPressed: _loadingProgress ? null : _fetchProgress,
                        icon: _loadingProgress
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(Icons.refresh),
                        label: Text(_loadingProgress ? 'Loading…' : 'Load'),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: 'Refresh users',
                        onPressed: _loadingUsers ? null : _fetchUsers,
                        icon: _loadingUsers
                            ? SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: theme.colorScheme.primary,
                                ),
                              )
                            : const Icon(Icons.person_search),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: _loadingProgress
                    ? const Center(child: CircularProgressIndicator())
                    : _progress.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.data_exploration,
                                    size: 48, color: theme.colorScheme.onSurfaceVariant),
                                const SizedBox(height: 16),
                                Text(
                                  'No progress found.\nTap "Load" to fetch data.',
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          )
                        : ListView.separated(
                            itemCount: _progress.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 8),
                            itemBuilder: (context, index) {
                              final p = _progress[index];
                              final user = p['user'] as Map<String, dynamic>?;
                              final name = user?['name'] ?? 'Unknown';
                              final uid = user?['id'];
                              final lesson = p['lesson'];
                              final score = p['score'];
                              final createdAt = p['created_at'];
                              final pending = (p['pending'] == true);

                              return Card(
                                color: theme.colorScheme.surfaceContainer,
                                child: ListTile(
                                  leading: CircleAvatar(
                                    backgroundColor: pending
                                        ? theme.colorScheme.tertiaryContainer
                                        : theme.colorScheme.primaryContainer,
                                    child: Text(
                                      score.toString(),
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: pending
                                            ? theme.colorScheme.onTertiaryContainer
                                            : theme.colorScheme.onPrimaryContainer,
                                      ),
                                    ),
                                  ),
                                  title: Row(
                                    children: [
                                      Flexible(
                                        child: Text(
                                          '$lesson',
                                          style: theme.textTheme.titleMedium,
                                        ),
                                      ),
                                      if (pending) ...[
                                        const SizedBox(width: 8),
                                        Tooltip(
                                          message: 'Pending sync',
                                          child: Icon(Icons.cloud_off, size: 18, color: theme.colorScheme.tertiary),
                                        ),
                                      ]
                                    ],
                                  ),
                                  subtitle: Text('User: $name (ID: $uid)\nRecorded: $createdAt'),
                                  isThreeLine: true,
                                  trailing: const Icon(Icons.chevron_right),
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

  String _prettyMap(Map<String, dynamic> data) {
    final buffer = StringBuffer('{ ');
    var i = 0;
    data.forEach((k, v) {
      if (i++ > 0) buffer.write(', ');
      buffer.write('$k: $v');
    });
    buffer.write(' }');
    return buffer.toString();
  }
}
