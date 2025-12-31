/// Result type for error handling without exceptions
///
/// This provides a functional approach to error handling,
/// similar to Rust's Result or Kotlin's Result.
sealed class Result<T> {
  const Result();

  /// Create a success result
  factory Result.success(T value) = Success<T>;

  /// Create a failure result
  factory Result.failure(String error, {String? code, dynamic details}) =
      Failure<T>;

  /// Check if the result is successful
  bool get isSuccess => this is Success<T>;

  /// Check if the result is a failure
  bool get isFailure => this is Failure<T>;

  /// Get the value if successful, or null if failed
  T? get valueOrNull => isSuccess ? (this as Success<T>).value : null;

  /// Get the error if failed, or null if successful
  String? get errorOrNull => isFailure ? (this as Failure<T>).error : null;

  /// Map the success value to a new type
  Result<R> map<R>(R Function(T value) mapper) {
    return switch (this) {
      Success(value: final v) => Result.success(mapper(v)),
      Failure(error: final e, code: final c, details: final d) =>
        Result.failure(e, code: c, details: d),
    };
  }

  /// Flat map the success value
  Result<R> flatMap<R>(Result<R> Function(T value) mapper) {
    return switch (this) {
      Success(value: final v) => mapper(v),
      Failure(error: final e, code: final c, details: final d) =>
        Result.failure(e, code: c, details: d),
    };
  }

  /// Get value or throw exception
  T getOrThrow() {
    return switch (this) {
      Success(value: final v) => v,
      Failure(error: final e) => throw Exception(e),
    };
  }

  /// Get value or return default
  T getOrElse(T defaultValue) {
    return switch (this) {
      Success(value: final v) => v,
      Failure() => defaultValue,
    };
  }

  /// Execute callback on success
  Result<T> onSuccess(void Function(T value) callback) {
    if (this is Success<T>) {
      callback((this as Success<T>).value);
    }
    return this;
  }

  /// Execute callback on failure
  Result<T> onFailure(void Function(String error) callback) {
    if (this is Failure<T>) {
      callback((this as Failure<T>).error);
    }
    return this;
  }
}

/// Success result containing a value
final class Success<T> extends Result<T> {
  final T value;

  const Success(this.value);

  @override
  String toString() => 'Success($value)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Success<T> &&
          runtimeType == other.runtimeType &&
          value == other.value;

  @override
  int get hashCode => value.hashCode;
}

/// Failure result containing an error
final class Failure<T> extends Result<T> {
  final String error;
  final String? code;
  final dynamic details;

  const Failure(this.error, {this.code, this.details});

  @override
  String toString() => 'Failure($error${code != null ? ', code: $code' : ''})';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Failure<T> &&
          runtimeType == other.runtimeType &&
          error == other.error &&
          code == other.code;

  @override
  int get hashCode => error.hashCode ^ (code?.hashCode ?? 0);
}
