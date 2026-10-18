// Homelab : télécommande SSH d'un serveur toujours allumé et d'une tour
// allumée à la demande. Voir app/README.md.
import 'dart:async';

import 'package:flutter/material.dart';

import 'src/dashboard_screen.dart';
import 'src/lock.dart';
import 'src/setup_screen.dart';
import 'src/store.dart';

void main() => runApp(const HomelabApp());

/// Délai en arrière-plan après lequel l'application se verrouille de nouveau.
const relockAfter = Duration(seconds: 60);

class HomelabApp extends StatefulWidget {
  const HomelabApp({super.key});

  @override
  State<HomelabApp> createState() => _HomelabAppState();
}

class _HomelabAppState extends State<HomelabApp> with WidgetsBindingObserver {
  bool _locked = true;
  bool _unlocking = false;
  String? _lockError;
  DateTime? _pausedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_unlock()));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _pausedAt = DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final since = _pausedAt;
      _pausedAt = null;
      if (!_locked && since != null && DateTime.now().difference(since) > relockAfter) {
        // Tout ce qui était affiché est retiré de l'écran et de la mémoire.
        setState(() => _locked = true);
        unawaited(_unlock());
      }
    }
  }

  Future<void> _unlock() async {
    if (_unlocking) return;
    setState(() {
      _unlocking = true;
      _lockError = null;
    });
    final error = await AppLock.unlock();
    if (!mounted) return;
    setState(() {
      _unlocking = false;
      _lockError = error;
      _locked = error != null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF9E9E9E),
      brightness: Brightness.dark,
    ).copyWith(surface: Colors.black);
    return MaterialApp(
      title: 'Homelab',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: scheme, scaffoldBackgroundColor: Colors.black),
      // Verrouillée : seul l'écran de verrouillage existe, les autres écrans
      // ne sont pas construits.
      builder: (context, child) => _locked
          ? LockScreen(busy: _unlocking, error: _lockError, onUnlock: () => unawaited(_unlock()))
          : child ?? const SizedBox.shrink(),
      home: const Root(),
    );
  }
}

/// Charge la clé et les réglages, puis affiche la configuration ou le tableau de bord.
class Root extends StatefulWidget {
  const Root({super.key});

  @override
  State<Root> createState() => _RootState();
}

class _RootState extends State<Root> {
  AppData? _data;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final data = await Store.load();
      if (mounted) setState(() => _data = data);
    } catch (e) {
      if (mounted) setState(() => _error = 'Stockage illisible : $e');
    }
  }

  Future<void> _reset({required bool all}) async {
    if (all) {
      await Store.clear();
    } else {
      await Store.forgetServer();
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    if (_error != null) {
      return Scaffold(body: Center(child: Padding(padding: const EdgeInsets.all(32), child: Text(_error!))));
    }
    if (data == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!data.ready) {
      return SetupScreen(initial: data, onDone: (d) => setState(() => _data = d));
    }
    return DashboardScreen(data: data, onReset: _reset);
  }
}
