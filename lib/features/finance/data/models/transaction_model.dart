import 'package:cloud_firestore/cloud_firestore.dart';

enum TransactionType { income, expense }

class TransactionModel {
  final String? firestoreId; // Adicionado: Para vincular com o Firestore
  final String title;
  final double amount;
  final TransactionType type;
  final String category;
  final DateTime date;

  TransactionModel({
    this.firestoreId, // Agora opcional, pois transações pendentes offline não têm
    required this.title,
    required this.amount,
    required this.type,
    required this.category,
    required this.date,
  });

  // Método para converter de Firestore para o Modelo
  factory TransactionModel.fromDrift(dynamic driftRow) {
  return TransactionModel(
    firestoreId: driftRow.firestoreId,
    title: driftRow.title,
    amount: driftRow.amount,
    type: TransactionType.values.byName(driftRow.type),
    category: driftRow.category,
    date: driftRow.date,
  );
}

  // Método para enviar para o Firestore
  Map<String, dynamic> toMap() {
    return {
      'title': title,
      'amount': amount,
      'type': type.name,
      'category': category,
      'date': Timestamp.fromDate(date),
    };
  }
}