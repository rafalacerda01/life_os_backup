import 'package:flutter/material.dart';

class CheckInScreen extends StatefulWidget {
  const CheckInScreen({super.key});

  @override
  State<CheckInScreen> createState() => _CheckInScreenState();
}

class _CheckInScreenState extends State<CheckInScreen> {
  double _energy = 3.0;
  double _focus = 3.0;
  double _motivation = 3.0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF070B14),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text("Check-in de Estado", style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("Como está seu alinhamento hoje?", style: TextStyle(color: Colors.white70, fontSize: 14)),
            const SizedBox(height: 30),
            _buildSliderRow("Nível de Energia ⚡", _energy, (val) => setState(() => _energy = val)),
            const SizedBox(height: 24),
            _buildSliderRow("Capacidade de Foco 🎯", _focus, (val) => setState(() => _focus = val)),
            const SizedBox(height: 24),
            _buildSliderRow("Motivação Interna 🚀", _motivation, (val) => setState(() => _motivation = val)),
            const Spacer(),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF5D0EFF),
                minimumSize: const Size(double.infinity, 56),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("Estado sincronizado no ecossistema."), backgroundColor: Colors.green),
                );
                Navigator.pop(context);
              },
              child: const Text("Registrar Métricas", style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
            )
          ],
        ),
      ),
    );
  }

  Widget _buildSliderRow(String label, double value, ValueChanged<double> onChanged) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
        Row(
          children: [
            const Text("Min", style: TextStyle(color: Colors.white38, fontSize: 12)),
            Expanded(
              child: Slider(
                value: value,
                min: 1.0,
                max: 5.0,
                divisions: 4,
                activeColor: const Color(0xFFB026FF),
                inactiveColor: Colors.white10,
                onChanged: onChanged,
              ),
            ),
            const Text("Max", style: TextStyle(color: Colors.white38, fontSize: 12)),
          ],
        ),
      ],
    );
  }
}