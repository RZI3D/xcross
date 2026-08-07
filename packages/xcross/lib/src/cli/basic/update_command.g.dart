// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'update_command.dart';

// **************************************************************************
// CliGenerator
// **************************************************************************

UpdateArgs _$parseUpdateArgsResult(ArgResults result) => UpdateArgs()
  ..check = result['check'] as bool
  ..to = result['to'] as String?
  ..force = result['force'] as bool
  ..yes = result['yes'] as bool;

ArgParser _$populateUpdateArgsParser(ArgParser parser) => parser
  ..addFlag(
    'check',
    help: 'Report the latest version without installing anything.',
    negatable: false,
  )
  ..addOption(
    'to',
    help: 'Install a specific release tag instead of the latest.',
    valueHelp: 'tag',
  )
  ..addFlag(
    'force',
    help: 'Reinstall even when the running version is already current.',
    negatable: false,
  )
  ..addFlag(
    'yes',
    abbr: 'y',
    help: 'Skip the confirmation prompt.',
    negatable: false,
  );

final _$parserForUpdateArgs = _$populateUpdateArgsParser(ArgParser());

UpdateArgs parseUpdateArgs(List<String> args) {
  final result = _$parserForUpdateArgs.parse(args);
  return _$parseUpdateArgsResult(result);
}

abstract class _$UpdateArgsCommand<T> extends Command<T> {
  _$UpdateArgsCommand() {
    _$populateUpdateArgsParser(argParser);
  }

  late final _options = _$parseUpdateArgsResult(argResults!);
}
