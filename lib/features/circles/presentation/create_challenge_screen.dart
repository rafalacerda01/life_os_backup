import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:life_os/core/theme/app_colors.dart';
import 'package:life_os/features/circles/domain/entities/challenge_entity.dart';
import 'package:life_os/features/circles/presentation/circles_provider.dart';

class CreateChallengeScreen extends ConsumerStatefulWidget {
  final String circleId;

  const CreateChallengeScreen({super.key, required this.circleId});

  @override
  ConsumerState<CreateChallengeScreen> createState() =>
      _CreateChallengeScreenState();
}

class _CreateChallengeScreenState extends ConsumerState<CreateChallengeScreen> {
  static const int _maxTargetValue = 1000000;

  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _targetValueController = TextEditingController();

  ChallengeType _selectedType = ChallengeType.focusMinutes;
  DateTime _endAt = DateTime.now().add(const Duration(days: 7));
  bool _isLoading = false;

  @override
  void dispose() {
    _titleController.dispose();
    _targetValueController.dispose();
    super.dispose();
  }

  Future<void> _selectEndDate() async {
    final now = DateTime.now();
    final firstDate = DateTime(now.year, now.month, now.day + 1);
    final lastDate = DateTime(now.year + 1, now.month, now.day);
    final selected = await showDatePicker(
      context: context,
      initialDate: _endAt,
      firstDate: firstDate,
      lastDate: lastDate,
    );

    if (selected != null && mounted) {
      setState(() {
        _endAt = DateTime(
          selected.year,
          selected.month,
          selected.day,
          23,
          59,
          59,
          999,
        );
      });
    }
  }

  Future<void> _handleCreateChallenge() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      final targetValue = int.tryParse(_targetValueController.text.trim()) ?? 0;

      await ref
          .read(circlesProvider.notifier)
          .createNewChallenge(
            title: _titleController.text.trim(),
            type: _selectedType,
            targetValue: targetValue,
            endAt: _endAt,
          );

      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Erro ao criar desafio: $error',
              style: const TextStyle(color: Colors.white),
            ),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final endDateLabel = MaterialLocalizations.of(
      context,
    ).formatMediumDate(_endAt);

    return Scaffold(
      backgroundColor: AppColors.scaffoldBackground,
      appBar: AppBar(
        title: const Text(
          'Novo Desafio',
          style: TextStyle(
            color: AppColors.textMain,
            fontWeight: FontWeight.bold,
          ),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: AppColors.textMain),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Motive o seu Círculo',
                style: TextStyle(
                  color: AppColors.textMain,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Defina uma meta coletiva baseada em ações reais do aplicativo.',
                style: TextStyle(color: AppColors.textHint, fontSize: 14),
              ),
              const SizedBox(height: 32),
              DropdownButtonFormField<ChallengeType>(
                initialValue: _selectedType,
                dropdownColor: AppColors.cardBackground,
                style: const TextStyle(color: AppColors.textMain),
                decoration: _fieldDecoration('Tipo de desafio'),
                items: ChallengeType.values
                    .map(
                      (type) => DropdownMenuItem(
                        value: type,
                        child: Text(type.label),
                      ),
                    )
                    .toList(),
                onChanged: _isLoading
                    ? null
                    : (type) {
                        if (type != null) {
                          setState(() => _selectedType = type);
                        }
                      },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _titleController,
                maxLength: 200,
                style: const TextStyle(color: AppColors.textMain),
                decoration: _fieldDecoration('Título do desafio'),
                validator: (value) {
                  final title = value?.trim() ?? '';
                  if (title.isEmpty) return 'Informe um título para o desafio';
                  if (title.length > 200) return 'Use no máximo 200 caracteres';
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _targetValueController,
                style: const TextStyle(color: AppColors.textMain),
                keyboardType: TextInputType.number,
                decoration: _fieldDecoration('Meta em ${_selectedType.label}'),
                validator: (value) {
                  final number = int.tryParse(value?.trim() ?? '');
                  if (number == null || number <= 0) {
                    return 'Informe um número maior que zero';
                  }
                  if (number > _maxTargetValue) {
                    return 'A meta máxima é $_maxTargetValue';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: _isLoading ? null : _selectEndDate,
                child: InputDecorator(
                  decoration: _fieldDecoration('Data final'),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        endDateLabel,
                        style: const TextStyle(color: AppColors.textMain),
                      ),
                      const Icon(
                        Icons.calendar_today_outlined,
                        color: AppColors.primary,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 40),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.secondary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    elevation: 0,
                  ),
                  onPressed: _isLoading ? null : _handleCreateChallenge,
                  child: _isLoading
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            color: AppColors.textMain,
                            strokeWidth: 2.5,
                          ),
                        )
                      : const Text(
                          'Criar Desafio',
                          style: TextStyle(
                            color: AppColors.textMain,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  InputDecoration _fieldDecoration(String label) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: AppColors.textHint),
      filled: true,
      fillColor: AppColors.cardBackground,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Colors.redAccent),
      ),
    );
  }
}
