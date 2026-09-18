// ignore_for_file: subtype_of_sealed_class

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/features/auth/presentation/providers/auth_provider.dart';
import 'package:life_os/features/circles/data/remote/circle_delete_remote_data_source.dart';
import 'package:life_os/features/circles/data/repositories/circles_repository.dart';
import 'package:life_os/features/circles/domain/entities/circle_entity.dart';
import 'package:life_os/features/circles/presentation/circles_provider.dart';
import 'package:life_os/features/circles/presentation/circles_screen.dart';

class _Firestore extends Fake implements FirebaseFirestore {}

class _User extends Fake implements User {
  @override
  String get uid => 'current-user';
}

class _Auth extends Fake implements FirebaseAuth {
  @override
  User? get currentUser => _User();
}

class _Gateway extends Fake implements CircleDeleteGateway {}

class _Repository extends CirclesRepository {
  _Repository() : super(_Firestore(), _Auth(), _Gateway());

  @override
  Future<String?> getUserActiveCircleId() async => null;
}

class _CirclesNotifier extends CirclesNotifier {
  _CirclesNotifier(this.circle);

  final CircleEntity circle;

  @override
  CirclesState build() => CirclesState(
    availableCircles: const [],
    joinedCircle: circle,
    isLoading: false,
  );
}

CircleMemberEntity _member(String id, String name, String? photoUrl) =>
    CircleMemberEntity(
      userId: id,
      displayName: name,
      photoUrl: photoUrl,
      role: CircleMemberRole.member,
      joinedAt: DateTime.utc(2026, 1, 1),
    );

CircleEntity _circle() => CircleEntity(
  id: 'circle-1',
  name: 'Circle',
  description: 'Description',
  adminId: 'admin',
  memberCount: 6,
  memberLimit: 30,
  schemaVersion: 2,
  members: [
    _member('cyber', 'Cyber', 'avatar_cyber'),
    _member('female', 'Female', 'avatar_female'),
    _member('male', 'Male', 'avatar_male'),
    _member('neural', 'Neural', 'avatar_neural'),
    _member('remote', 'Remote', 'https://images.example.test/profile.jpg'),
    _member('none', 'No Photo', null),
  ],
  challenges: const [],
);

void main() {
  testWidgets('renderiza avatares simbólicos, URL remota e inicial', (
    tester,
  ) async {
    final circle = _circle();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          firebaseAuthProvider.overrideWithValue(_Auth()),
          circlesRepositoryProvider.overrideWithValue(_Repository()),
          circlesProvider.overrideWith(() => _CirclesNotifier(circle)),
        ],
        child: const MaterialApp(home: CirclesScreen()),
      ),
    );
    await tester.pump();

    final avatars = tester
        .widgetList<CircleAvatar>(find.byType(CircleAvatar))
        .toList();
    expect(avatars, hasLength(6));

    for (final index in <int>[0, 2, 3]) {
      expect(avatars[index].backgroundImage, isNull);
      expect((avatars[index].child! as Icon).icon, Icons.face);
    }

    expect(avatars[1].backgroundImage, isNull);
    expect((avatars[1].child! as Icon).icon, Icons.face_3);

    final remoteImage = avatars[4].backgroundImage! as NetworkImage;
    expect(remoteImage.url, 'https://images.example.test/profile.jpg');
    expect(avatars[4].child, isNull);

    expect(avatars[5].backgroundImage, isNull);
    expect((avatars[5].child! as Text).data, 'N');

    final imageError = tester.takeException();
    if (imageError != null) {
      expect(imageError, isA<NetworkImageLoadException>());
    }
  });
}
