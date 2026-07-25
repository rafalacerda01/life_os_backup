import 'package:equatable/equatable.dart';

enum TransactionType { income, expense }

class TransactionEntity extends Equatable {
  final String id;
  final String title;
  final double amount;
  final TransactionType type;
  final String category;
  final DateTime date;

  const TransactionEntity({
    required this.id,
    required this.title,
    required this.amount,
    required this.type,
    required this.category,
    required this.date,
  });

  @override
  List<Object?> get props => [id, title, amount, type, category, date];
}