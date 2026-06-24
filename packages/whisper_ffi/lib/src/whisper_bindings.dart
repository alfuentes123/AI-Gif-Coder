import 'dart:ffi';

@Native<
  Int32 Function(
    Pointer<Char>,
    Pointer<Char>,
    Pointer<Char>,
    Int32,
    Pointer<Char>,
    Int32,
  )
>(
  symbol: 'whisper_ffi_transcribe',
  assetId: 'package:whisper_ffi/src/whisper_bindings.dart',
)
external int whisperFfiTranscribe(
  Pointer<Char> modelPath,
  Pointer<Char> wavPath,
  Pointer<Char> output,
  int outputCapacity,
  Pointer<Char> errorOutput,
  int errorCapacity,
);

@Native<Void Function()>(
  symbol: 'whisper_ffi_cancel',
  assetId: 'package:whisper_ffi/src/whisper_bindings.dart',
)
external void whisperFfiCancel();
