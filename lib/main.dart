import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'providers/transfer_state.dart';
import 'ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final state = TransferState();
  await state.init();

  runApp(
    ChangeNotifierProvider<TransferState>(
      create: (_) => state,
      child: const P2PTransferApp(),
    ),
  );
}

class P2PTransferApp extends StatelessWidget {
  const P2PTransferApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'P2P 文件传输',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.blue,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1A73E8),
        ),
        useMaterial3: true,
        fontFamily: 'sans-serif',
      ),
      home: const HomePage(),
    );
  }
}
