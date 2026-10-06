/// A session admission checked synchronously at each remote send boundary.
/// It owns no lease: session detach never waits for network completion.
class RemoteSendPermit {
  const RemoteSendPermit(this._isCurrent);
  final bool Function() _isCurrent;

  bool get isCurrent => _isCurrent();

  RemoteSendPermit and(bool Function() isCurrent) =>
      RemoteSendPermit(() => this.isCurrent && isCurrent());

  void requireCurrent() {
    if (!isCurrent) throw const RemoteSessionStopped();
  }
}

class RemoteSessionStopped implements Exception {
  const RemoteSessionStopped();
  @override
  String toString() => 'A sessão não permite concluir esta operação.';
}
