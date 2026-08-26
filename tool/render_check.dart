// Minimal render check: no window_manager, no providers, just paint.
//
//   flutter build windows --debug -t tool/render_check.dart
//   build/windows/x64/runner/Debug/marmelade.exe
//
// Exists to separate "Flutter is not rendering here" from "the app is broken".
// If this shows an orange box on a dark background, the engine and the window
// are fine and any blank app window is the app's fault. If this is blank too,
// the problem is below the app.
//
// Note: the Windows engine composites through ANGLE, so OS-level screen
// captures of a Flutter window can come back blank even while the window looks
// correct on screen. Trust your eyes over a screenshot here.
import 'package:flutter/material.dart';

void main() {
  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      backgroundColor: const Color(0xFF102030),
      body: Center(
        child: Container(
          width: 400,
          height: 200,
          color: const Color(0xFFE8730C),
          child: const Center(
            child: Text('RENDER OK', style: TextStyle(fontSize: 32)),
          ),
        ),
      ),
    ),
  ));
}
