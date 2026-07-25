import '../../data/models/flashcard_model.dart';

class FlashcardModel {
  final String id;
  final String question;
  final String answer;

  FlashcardModel({
    required this.id, 
    required this.question, 
    required this.answer
  });

  factory FlashcardModel.fromMap(Map<String, dynamic> map, String id) {
    return FlashcardModel(
      id: id,
      question: map['question'] ?? '',
      answer: map['answer'] ?? '',
    );
  }
}