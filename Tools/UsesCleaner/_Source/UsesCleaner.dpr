program UsesCleaner;

{$APPTYPE CONSOLE}

{$R *.res}

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.Types,
  System.StrUtils,
  System.Math,
  System.Generics.Collections,
  System.Win.Registry,
  Winapi.Windows,
  Alcinoe.StringList,
  Alcinoe.StringUtils,
  Alcinoe.Execute,
  Alcinoe.Common;

type

  {~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~}
  EUsesParseError = class(Exception);

  {~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~}
  TUsesItemKind = (uikUnit, uikDirective, uikComment);

  {~~~~~~~~~~~~~~~~~~~~~~~~}
  TUsesItem = class(TObject)
  public
    Kind: TUsesItemKind;
    Text: AnsiString;            // The unit name, the compiler directive or the comment
    TrailingComment: AnsiString; // A comment located on the same line, after the unit name
    Removed: Boolean;
    MovedFromInterface: Boolean; // The unit was moved from the interface uses clause to
                                 // the implementation uses clause (its removal was already
                                 // tested so it must not be tested again)
  end;

  {~~~~~~~~~~~~~~~~~~~~~~~~~~}
  TUsesClause = class(TObject)
  public
    Items: TObjectList<TUsesItem>;
    IsInterface: Boolean; // The clause is located in the interface section
    Synthetic: Boolean;   // The clause did not exist in the original source; it was
                          // created right after the "implementation" keyword to be
                          // able to move units from the interface uses clause
    constructor Create;
    destructor Destroy; override;
    function ActiveUnitCount: Integer;
    function HasDirectiveOrComment: Boolean;
    function GenerateSource: AnsiString;
  end;

  {~~~~~~~~~~~~~~~~~~~~~~~~~~}
  TSourceFile = class(TObject)
  public
    FilePath: String;
    OriginalSource: AnsiString;
    Segments: TList<AnsiString>;       // Segments[I] is the raw source located before Clauses[I];
                                       // the last segment is the raw source after the last clause
    Clauses: TObjectList<TUsesClause>;
    BackupDone: Boolean;
    Modified: Boolean;
    constructor Create;
    destructor Destroy; override;
    function GenerateSource: AnsiString;
  end;

var
  GProject: String;
  GProjectDir: String;
  GRsVars: String;
  GConfigs: TArray<String>;
  GPlatforms: TArray<String>;
  GCreateBackup: Boolean = False;
  GInteractive: Boolean = False;
  GBuildCount: Integer = 0;
  GBaselineWarnings: TObjectDictionary<String, TALStringListA>;

{**********************************************************}
function IsIdentStartChar(const AChar: AnsiChar): Boolean;
begin
  Result := AChar in ['A'..'Z', 'a'..'z', '_'];
end;

{*****************************************************}
function IsIdentChar(const AChar: AnsiChar): Boolean;
begin
  Result := AChar in ['A'..'Z', 'a'..'z', '0'..'9', '_'];
end;

{**************************************************************}
// Returns the keyword of a compiler directive like '{$IFDEF X}'
function GetDirectiveKeyword(const AText: AnsiString): AnsiString;
var I: Integer;
begin
  I := 3; // skip '{$'
  while (I <= Length(AText)) and (AText[I] in ['A'..'Z', 'a'..'z']) do inc(I);
  Result := ALCopyStr(AText, 3, I - 3);
end;

{***********************************************************}
// Returns +1 for {$IF/$IFDEF/$IFNDEF/$IFOPT}, -1 for
// {$ENDIF/$IFEND} and 0 for any other compiler directive
function GetDirectiveDelta(const AText: AnsiString): Integer;
var LKeyword: AnsiString;
begin
  Result := 0;
  LKeyword := GetDirectiveKeyword(AText);
  if ALSameTextA(LKeyword, 'IF') or
     ALSameTextA(LKeyword, 'IFDEF') or
     ALSameTextA(LKeyword, 'IFNDEF') or
     ALSameTextA(LKeyword, 'IFOPT') then Result := 1
  else if ALSameTextA(LKeyword, 'ENDIF') or
          ALSameTextA(LKeyword, 'IFEND') then Result := -1;
end;

{**************************}
constructor TUsesClause.Create;
begin
  inherited Create;
  Items := TObjectList<TUsesItem>.Create(True{AOwnsObjects});
  IsInterface := False;
  Synthetic := False;
end;

{**************************}
destructor TUsesClause.Destroy;
begin
  ALFreeAndNil(Items);
  inherited Destroy;
end;

{******************************************}
function TUsesClause.ActiveUnitCount: Integer;
begin
  Result := 0;
  for var LItem in Items do
    if (LItem.Kind = uikUnit) and (not LItem.Removed) then inc(Result);
end;

{*************************************************}
function TUsesClause.HasDirectiveOrComment: Boolean;
begin
  Result := False;
  for var LItem in Items do
    if LItem.Kind in [uikDirective, uikComment] then exit(True);
end;

{***********************************************}
function TUsesClause.GenerateSource: AnsiString;
var LDepths: TArray<Integer>;
    LDepth: Integer;
    LFirstUnitIdx: Integer;
    LLastUnitIdx: Integer;
    LLastUncondUnitIdx: Integer;
    LTrailingDirective: Boolean;
    LSemicolonDone: Boolean;
    LLine: AnsiString;
    LItem: TUsesItem;
    I: Integer;
begin

  // Compute the conditional compilation depth of every item
  SetLength(LDepths, Items.Count);
  LDepth := 0;
  for I := 0 to Items.Count - 1 do begin
    LItem := Items[I];
    if (LItem.Kind = uikDirective) and (GetDirectiveDelta(LItem.Text) < 0) then dec(LDepth);
    LDepths[I] := LDepth;
    if (LItem.Kind = uikDirective) and (GetDirectiveDelta(LItem.Text) > 0) then inc(LDepth);
  end;

  // Locate the first unit, the last unit and the last unit
  // that is not nested inside a conditional compilation block
  LFirstUnitIdx := -1;
  LLastUnitIdx := -1;
  LLastUncondUnitIdx := -1;
  for I := 0 to Items.Count - 1 do begin
    LItem := Items[I];
    if (LItem.Kind = uikUnit) and (not LItem.Removed) then begin
      if LFirstUnitIdx < 0 then LFirstUnitIdx := I;
      LLastUnitIdx := I;
      if LDepths[I] = 0 then LLastUncondUnitIdx := I;
    end;
  end;

  // When no unit remains the whole clause is dropped. This is only
  // allowed when the clause does not contain any compiler directive
  // or comment (the caller must enforce it)
  if LLastUnitIdx < 0 then begin
    if HasDirectiveOrComment then raise Exception.Create('Cannot generate an empty uses clause that contains compiler directives or comments');
    exit('');
  end;

  // Check if a compiler directive follows the last unconditional unit
  LTrailingDirective := False;
  if LLastUncondUnitIdx >= 0 then
    for I := LLastUncondUnitIdx + 1 to Items.Count - 1 do
      if Items[I].Kind = uikDirective then begin
        LTrailingDirective := True;
        break;
      end;

  Result := 'uses' + #13#10;
  LSemicolonDone := False;
  for I := 0 to Items.Count - 1 do begin
    LItem := Items[I];
    if LItem.Removed then continue;
    if LItem.Kind in [uikDirective, uikComment] then LLine := '  ' + LItem.Text
    else begin
      if (LLastUncondUnitIdx >= 0) and (I < LLastUncondUnitIdx) then LLine := '  ' + LItem.Text + ','
      else if I = LLastUncondUnitIdx then begin
        if (I = LLastUnitIdx) and (not LTrailingDirective) then begin
          LLine := '  ' + LItem.Text + ';';
          LSemicolonDone := True;
        end
        else LLine := '  ' + LItem.Text;
      end
      else begin
        // Units located after the last unconditional unit are all nested
        // inside conditional compilation blocks. Use a leading comma so
        // that the clause stays valid whatever branches are active
        if I = LFirstUnitIdx then LLine := '  ' + LItem.Text
        else LLine := '  , ' + LItem.Text;
      end;
      if LItem.TrailingComment <> '' then LLine := LLine + ' ' + LItem.TrailingComment;
    end;
    Result := Result + LLine + #13#10;
  end;
  if not LSemicolonDone then Result := Result + '  ;' + #13#10;
  Result := ALTrimRight(Result);

end;

{**************************}
constructor TSourceFile.Create;
begin
  inherited Create;
  Segments := TList<AnsiString>.Create;
  Clauses := TObjectList<TUsesClause>.Create(True{AOwnsObjects});
  BackupDone := False;
  Modified := False;
end;

{**************************}
destructor TSourceFile.Destroy;
begin
  ALFreeAndNil(Segments);
  ALFreeAndNil(Clauses);
  inherited Destroy;
end;

{***********************************************}
function TSourceFile.GenerateSource: AnsiString;

  {~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~}
  function StripLeadingEol(const AStr: AnsiString): AnsiString;
  begin
    if (Length(AStr) >= 2) and (AStr[1] = #13) and (AStr[2] = #10) then Result := ALCopyStr(AStr, 3, MaxInt)
    else if (Length(AStr) >= 1) and (AStr[1] in [#13, #10]) then Result := ALCopyStr(AStr, 2, MaxInt)
    else Result := AStr;
  end;

var LClauseSrc: AnsiString;
    LSegment: AnsiString;
    LSkipEol: Boolean;
    I: Integer;
begin
  Result := '';
  LSkipEol := False;
  for I := 0 to Clauses.Count - 1 do begin
    LSegment := Segments[I];
    if LSkipEol then LSegment := StripLeadingEol(LSegment);
    Result := Result + LSegment;
    LClauseSrc := Clauses[I].GenerateSource;
    // A synthetic clause is anchored right after the "implementation"
    // keyword so it needs an empty line before the "uses" keyword
    if (LClauseSrc <> '') and Clauses[I].Synthetic then LClauseSrc := #13#10 + #13#10 + LClauseSrc;
    Result := Result + LClauseSrc;
    LSkipEol := (LClauseSrc = '') and (not Clauses[I].Synthetic);
  end;
  LSegment := Segments[Segments.Count - 1];
  if LSkipEol then LSegment := StripLeadingEol(LSegment);
  Result := Result + LSegment;
end;

{*******************************}
procedure ParseUsesClause(
            const ASource: AnsiString;
            var AIndex: Integer;
            const AClause: TUsesClause);

var LLastUnit: TUsesItem;
    LSawNewLine: Boolean;

  {~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~}
  procedure AddComment(const AText: AnsiString);
  var LItem: TUsesItem;
  begin
    if (LLastUnit <> nil) and (not LSawNewLine) then begin
      if LLastUnit.TrailingComment <> '' then LLastUnit.TrailingComment := LLastUnit.TrailingComment + ' ';
      LLastUnit.TrailingComment := LLastUnit.TrailingComment + AText;
    end
    else begin
      LItem := TUsesItem.Create;
      LItem.Kind := uikComment;
      LItem.Text := AText;
      AClause.Items.Add(LItem);
    end;
  end;

var LLen, J: Integer;
    C: AnsiChar;
    LText, LName: AnsiString;
    LItem: TUsesItem;
begin
  LLen := Length(ASource);
  LLastUnit := nil;
  LSawNewLine := False;
  while AIndex <= LLen do begin
    C := ASource[AIndex];

    // whitespaces
    if C in [' ', #9] then inc(AIndex)

    // line breaks
    else if C in [#13, #10] then begin
      LSawNewLine := True;
      inc(AIndex);
    end

    // separator
    else if C = ',' then inc(AIndex)

    // end of the clause
    else if C = ';' then begin
      inc(AIndex);
      exit;
    end

    // {$directive} or { comment }
    else if C = '{' then begin
      J := AIndex + 1;
      while (J <= LLen) and (ASource[J] <> '}') do inc(J);
      if J > LLen then raise EUsesParseError.Create('Unterminated "{" comment inside a uses clause');
      LText := ALCopyStr(ASource, AIndex, J - AIndex + 1);
      AIndex := J + 1;
      if (Length(LText) >= 2) and (LText[2] = '$') then begin
        LItem := TUsesItem.Create;
        LItem.Kind := uikDirective;
        LItem.Text := LText;
        AClause.Items.Add(LItem);
        LLastUnit := nil;
        LSawNewLine := False;
      end
      else AddComment(LText);
    end

    // // comment
    else if (C = '/') and (AIndex < LLen) and (ASource[AIndex + 1] = '/') then begin
      J := AIndex;
      while (J <= LLen) and (not (ASource[J] in [#13, #10])) do inc(J);
      AddComment(ALTrimRight(ALCopyStr(ASource, AIndex, J - AIndex)));
      AIndex := J;
    end

    // (* comment *)
    else if (C = '(') and (AIndex < LLen) and (ASource[AIndex + 1] = '*') then begin
      J := AIndex + 2;
      while (J < LLen) and (not ((ASource[J] = '*') and (ASource[J + 1] = ')'))) do inc(J);
      if J >= LLen then raise EUsesParseError.Create('Unterminated "(*" comment inside a uses clause');
      AddComment(ALCopyStr(ASource, AIndex, J + 2 - AIndex));
      AIndex := J + 2;
    end

    // unit name
    else if IsIdentStartChar(C) or (C = '&') then begin
      J := AIndex;
      if ASource[J] = '&' then inc(J);
      while (J <= LLen) and (IsIdentChar(ASource[J]) or (ASource[J] = '.')) do inc(J);
      LName := ALCopyStr(ASource, AIndex, J - AIndex);
      AIndex := J;
      if ALSameTextA(LName, 'in') then raise EUsesParseError.Create('".dpr style" uses clauses (unit in ''filename'') are not supported');
      LItem := TUsesItem.Create;
      LItem.Kind := uikUnit;
      LItem.Text := LName;
      AClause.Items.Add(LItem);
      LLastUnit := LItem;
      LSawNewLine := False;
    end

    else raise EUsesParseError.CreateFmt('Unexpected character "%s" inside a uses clause', [Char(C)]);

  end;
  raise EUsesParseError.Create('Unterminated uses clause (";" not found)');
end;

{********************************}
procedure ParseSourceFile(
            const ASource: AnsiString;
            const ASourceFile: TSourceFile);
var LLen, I, LSegStart, LWordStart: Integer;
    LSeenImplementation: Boolean;
    LImplKeywordEnd: Integer;
    LImplSegStart: Integer;
    C: AnsiChar;
    LWord: AnsiString;
    LClause: TUsesClause;
begin
  LLen := Length(ASource);
  I := 1;
  LSegStart := 1;
  LSeenImplementation := False;
  LImplKeywordEnd := 0;
  LImplSegStart := 0;
  while I <= LLen do begin
    C := ASource[I];

    // // comment
    if (C = '/') and (I < LLen) and (ASource[I + 1] = '/') then begin
      while (I <= LLen) and (not (ASource[I] in [#13, #10])) do inc(I);
    end

    // { comment } or {$directive}
    else if C = '{' then begin
      while (I <= LLen) and (ASource[I] <> '}') do inc(I);
      inc(I);
    end

    // (* comment *)
    else if (C = '(') and (I < LLen) and (ASource[I + 1] = '*') then begin
      inc(I, 2);
      while (I < LLen) and (not ((ASource[I] = '*') and (ASource[I + 1] = ')'))) do inc(I);
      inc(I, 2);
    end

    // 'string literal'
    else if C = '''' then begin
      inc(I);
      while (I <= LLen) and (ASource[I] <> '''') do inc(I);
      inc(I);
    end

    // identifier / keyword
    else if IsIdentStartChar(C) then begin
      LWordStart := I;
      while (I <= LLen) and IsIdentChar(ASource[I]) do inc(I);
      LWord := ALCopyStr(ASource, LWordStart, I - LWordStart);
      if ALSameTextA(LWord, 'uses') and
         ((LWordStart = 1) or (not (ASource[LWordStart - 1] in ['.', '&']))) then begin
        ASourceFile.Segments.Add(ALCopyStr(ASource, LSegStart, LWordStart - LSegStart));
        LClause := TUsesClause.Create;
        LClause.IsInterface := not LSeenImplementation;
        ASourceFile.Clauses.Add(LClause);
        ParseUsesClause(ASource, I, LClause);
        LSegStart := I;
      end
      else if ALSameTextA(LWord, 'implementation') and
              ((LWordStart = 1) or (not (ASource[LWordStart - 1] in ['.', '&']))) then begin
        LSeenImplementation := True;
        LImplKeywordEnd := I;
        LImplSegStart := LSegStart;
      end;
    end

    else inc(I);

  end;
  ASourceFile.Segments.Add(ALCopyStr(ASource, LSegStart, LLen - LSegStart + 1));

  // Synthesize an empty implementation uses clause when the file has uses
  // clauses but none in the implementation section. It is anchored right
  // after the "implementation" keyword so that units of the interface uses
  // clause can be moved to the implementation section
  if LSeenImplementation and (ASourceFile.Clauses.Count > 0) then begin
    var LHasImplClause := False;
    for var LC in ASourceFile.Clauses do
      if not LC.IsInterface then LHasImplClause := True;
    if not LHasImplClause then begin
      var LSeg := ASourceFile.Segments[ASourceFile.Segments.Count - 1];
      var LRelPos := LImplKeywordEnd - LImplSegStart + 1;
      LClause := TUsesClause.Create;
      LClause.IsInterface := False;
      LClause.Synthetic := True;
      ASourceFile.Clauses.Add(LClause);
      ASourceFile.Segments[ASourceFile.Segments.Count - 1] := ALCopyStr(LSeg, 1, LRelPos - 1);
      ASourceFile.Segments.Add(ALCopyStr(LSeg, LRelPos, MaxInt));
    end;
  end;

end;

{*******************************************************************}
// Returns the conditional compilation directives that surround AItem
// inside AClause: for each enclosing block, its opening {$IF...} plus
// any {$ELSEIF}/{$ELSE} encountered before AItem. Empty when AItem is
// not nested inside any conditional compilation block
function GetGuardPath(
           const AClause: TUsesClause;
           const ATargetItem: TUsesItem): TArray<AnsiString>;
var LLevelStart: TArray<Integer>;
    LKeyword: AnsiString;
    LItem: TUsesItem;
    I: Integer;
begin
  SetLength(Result, 0);
  SetLength(LLevelStart, 0);
  for I := 0 to AClause.Items.Count - 1 do begin
    LItem := AClause.Items[I];
    if LItem = ATargetItem then exit;
    if LItem.Kind <> uikDirective then continue;
    LKeyword := GetDirectiveKeyword(LItem.Text);
    if ALSameTextA(LKeyword, 'IF') or
       ALSameTextA(LKeyword, 'IFDEF') or
       ALSameTextA(LKeyword, 'IFNDEF') or
       ALSameTextA(LKeyword, 'IFOPT') then begin
      LLevelStart := LLevelStart + [Length(Result)];
      Result := Result + [LItem.Text];
    end
    else if ALSameTextA(LKeyword, 'ENDIF') or
            ALSameTextA(LKeyword, 'IFEND') then begin
      if Length(LLevelStart) > 0 then begin
        SetLength(Result, LLevelStart[High(LLevelStart)]);
        SetLength(LLevelStart, Length(LLevelStart) - 1);
      end;
    end
    else if (ALSameTextA(LKeyword, 'ELSE') or ALSameTextA(LKeyword, 'ELSEIF')) and
            (Length(LLevelStart) > 0) then
      Result := Result + [LItem.Text];
  end;
end;

{****************************************************************}
function GuardSignature(const APath: TArray<AnsiString>): AnsiString;
var I: Integer;
begin
  Result := '';
  for I := 0 to High(APath) do
    Result := Result + APath[I] + '|';
end;

{**********************************************************************}
function CountOpeningDirectives(const APath: TArray<AnsiString>): Integer;
var I: Integer;
begin
  Result := 0;
  for I := 0 to High(APath) do
    if GetDirectiveDelta(APath[I]) > 0 then inc(Result);
end;

{***********************************}
function ClauseContainsActiveUnit(
           const AClause: TUsesClause;
           const AName: AnsiString): Boolean;
begin
  Result := False;
  for var LItem in AClause.Items do
    if (LItem.Kind = uikUnit) and (not LItem.Removed) and ALSameTextA(LItem.Text, AName) then exit(True);
end;

{***********************************************************************}
// Replace line numbers like "(123)" by "()" so that a warning stays
// identical to its baseline counterpart even when lines are shifted
// by the removal of unit references
function NormalizeWarningLine(const ALine: AnsiString): AnsiString;
var I, J: Integer;
begin
  Result := '';
  I := 1;
  while I <= Length(ALine) do begin
    if ALine[I] = '(' then begin
      J := I + 1;
      while (J <= Length(ALine)) and (ALine[J] in ['0'..'9']) do inc(J);
      if (J > I + 1) and (J <= Length(ALine)) and (ALine[J] = ')') then begin
        Result := Result + '()';
        I := J + 1;
        continue;
      end;
    end;
    Result := Result + ALine[I];
    inc(I);
  end;
end;

{**********************************}
function CreateWarningList: TALStringListA;
begin
  Result := TALStringListA.Create;
  Result.Sorted := True;
  Result.Duplicates := TDuplicates.dupIgnore;
  Result.CaseSensitive := False;
end;

{*******************************}
procedure ExtractWarnings(
            const AOutput: AnsiString;
            const AWarnings: TALStringListA);
var LLines: TALStringListA;
    LLine: AnsiString;
    I: Integer;
begin
  LLines := TALStringListA.Create;
  try
    LLines.Text := AOutput;
    for I := 0 to LLines.Count - 1 do begin
      LLine := ALTrim(LLines[I]);
      if LLine = '' then continue;
      if ALPosA('Warning(s)', LLine) > 0 then continue; // MSBuild summary line
      if ALPosIgnoreCaseA('failed to read line prolog', LLine) > 0 then continue; // spurious compiler/debug info noise
      if (ALPosA('Warning: ', LLine) > 0) or             // dcc warnings
         (ALPosIgnoreCaseA(' warning ', LLine) > 0) then // MSBuild warnings
        AWarnings.Add(NormalizeWarningLine(LLine));
    end;
  finally
    ALFreeAndNil(LLines);
  end;
end;

{*****************************}
function FirstNewWarning(
           const ABaseline: TALStringListA;
           const ACurrent: TALStringListA): AnsiString;
var I: Integer;
begin
  Result := '';
  for I := 0 to ACurrent.Count - 1 do
    if ABaseline.IndexOf(ACurrent[I]) < 0 then exit(ACurrent[I]);
end;

{**********************************************************}
function PairKey(const AConfig, APlatform: String): String;
begin
  Result := AConfig + '|' + APlatform;
end;

{**************************}
function RunMSBuild(
           const ATarget: String;
           const AConfig: String;
           const APlatform: String;
           const AWarnings: TALStringListA; // can be nil
           out AOutput: AnsiString): Boolean;
var LOutputStream: TMemoryStream;
    LCommandLine: String;
    LExitCode: DWORD;
begin
  LOutputStream := TMemoryStream.Create;
  try
    LCommandLine :=
      'cmd.exe /S /C ""' + GRsVars + '" && msbuild "' + GProject + '"' +
      ' /t:' + ATarget +
      ' /p:Config=' + AConfig +
      ' /p:Platform=' + APlatform +
      ' /nologo /v:m"';
    LExitCode := ALWinExecW(LCommandLine, GProjectDir, ''{aEnvironment}, nil{aInputStream}, LOutputStream);
    inc(GBuildCount);
    SetLength(AOutput, LOutputStream.Size);
    if LOutputStream.Size > 0 then ALMove(LOutputStream.Memory^, PAnsiChar(AOutput)^, LOutputStream.Size);
    Result := LExitCode = 0;
    if AWarnings <> nil then ExtractWarnings(AOutput, AWarnings);
  finally
    ALFreeAndNil(LOutputStream);
  end;
end;

{*************************************************}
procedure PrintBuildOutputTail(const AOutput: AnsiString);
var LLines: TALStringListA;
    I: Integer;
begin
  LLines := TALStringListA.Create;
  try
    LLines.Text := AOutput;
    for I := Max(0, LLines.Count - 25) to LLines.Count - 1 do
      if ALTrim(LLines[I]) <> '' then
        Writeln('    ' + LLines[I]);
  finally
    ALFreeAndNil(LLines);
  end;
end;

{***********************************************}
function Unquote(const AStr: String): String;
begin
  Result := Trim(AStr);
  if (Length(Result) >= 2) and (Result[1] = '"') and (Result[Length(Result)] = '"') then
    Result := Copy(Result, 2, Length(Result) - 2);
end;

{**********************************}
function AskUser(
           const APrompt: String;
           const ADefault: String): String;
begin
  GInteractive := True;
  if ADefault <> '' then Write(APrompt + ' [' + ADefault + ']: ')
  else Write(APrompt + ': ');
  Readln(Result);
  Result := Unquote(Result);
  if Result = '' then Result := ADefault;
end;

{***********************************************}
function SplitList(const AStr: String): TArray<String>;
var LToken, LItem: String;
begin
  SetLength(Result, 0);
  for LToken in SplitString(AStr, ';') do begin
    LItem := Unquote(LToken);
    if LItem <> '' then Result := Result + [LItem];
  end;
end;

{******************************}
function FindRsVars: String;
var LRegistry: TRegistry;
    LVersion, LPath, LRootDir: String;
begin
  Result := '';
  LRegistry := TRegistry.Create(KEY_READ);
  try
    LRegistry.RootKey := HKEY_LOCAL_MACHINE;
    for LVersion in TArray<String>.Create('37.0', '23.0', '22.0', '21.0') do
      for LPath in TArray<String>.Create('SOFTWARE\Embarcadero\BDS\', 'SOFTWARE\WOW6432Node\Embarcadero\BDS\') do
        if LRegistry.OpenKeyReadOnly(LPath + LVersion) then begin
          if LRegistry.ValueExists('RootDir') then LRootDir := LRegistry.ReadString('RootDir')
          else LRootDir := '';
          LRegistry.CloseKey;
          if (LRootDir <> '') and
             TFile.Exists(IncludeTrailingPathDelimiter(LRootDir) + 'bin\rsvars.bat') then
            exit(IncludeTrailingPathDelimiter(LRootDir) + 'bin\rsvars.bat');
        end;
  finally
    ALFreeAndNil(LRegistry);
  end;
end;

{*************************************************}
procedure EnsureBackup(const ASourceFile: TSourceFile);
begin
  if GCreateBackup and (not ASourceFile.BackupDone) then begin
    if TFile.Exists(ASourceFile.FilePath + '.bak') then raise Exception.CreateFmt('The backup file (%s) already exists!', [ASourceFile.FilePath + '.bak']);
    TFile.Copy(ASourceFile.FilePath, ASourceFile.FilePath + '.bak');
  end;
  ASourceFile.BackupDone := True;
end;

{***************************************************}
procedure SaveSourceFile(const ASourceFile: TSourceFile);
begin
  EnsureBackup(ASourceFile);
  ALSaveStringtoFile(ASourceFile.GenerateSource, ASourceFile.FilePath);
  ASourceFile.Modified := True;
end;

{*******************************************************************}
// Rebuild every selected configuration/platform pair. Returns False
// (with the reason) as soon as one build fails or introduces a
// warning that was not present in the baseline build
function TestBuildAllPairs(out AReason: String): Boolean;
var LWarnings: TALStringListA;
    LOutput: AnsiString;
    LNewWarning: AnsiString;
begin
  for var LConfig in GConfigs do
    for var LPlatform in GPlatforms do begin
      LWarnings := CreateWarningList;
      try
        if not RunMSBuild('Make', LConfig, LPlatform, LWarnings, LOutput) then begin
          AReason := 'build failed on ' + LConfig + '/' + LPlatform;
          exit(False);
        end;
        LNewWarning := FirstNewWarning(GBaselineWarnings[PairKey(LConfig, LPlatform)], LWarnings);
        if LNewWarning <> '' then begin
          AReason := 'new warning on ' + LConfig + '/' + LPlatform + ': ' + String(LNewWarning);
          exit(False);
        end;
      finally
        ALFreeAndNil(LWarnings);
      end;
    end;
  AReason := '';
  Result := True;
end;

{*******************************************************************}
// Temporarily inject a syntax error at the top of the file and check
// that at least one configuration/platform pair fails to build. If
// none fails then the file is not compiled by the project and it
// would be unsafe to process it (every removal would be accepted)
function ProbeFileUsed(const ASourceFile: TSourceFile): Boolean;
var LOutput: AnsiString;
begin
  EnsureBackup(ASourceFile);
  ALSaveStringtoFile('!!! UsesCleaner probe - this line must not compile !!!' + #13#10 + ASourceFile.GenerateSource, ASourceFile.FilePath);
  try
    Result := False;
    for var LConfig in GConfigs do
      for var LPlatform in GPlatforms do
        if not RunMSBuild('Make', LConfig, LPlatform, nil{AWarnings}, LOutput) then
          exit(True);
  finally
    ALSaveStringtoFile(ASourceFile.GenerateSource, ASourceFile.FilePath);
  end;
end;

{*******************************}
procedure RunBaselineBuilds;
var LWarnings: TALStringListA;
    LOutput: AnsiString;
    LSuccess: Boolean;
    I: Integer;
begin
  for var LConfig in GConfigs do
    for var LPlatform in GPlatforms do begin
      Write('Baseline build (' + LConfig + '/' + LPlatform + ') ... ');
      LWarnings := CreateWarningList;
      LSuccess := RunMSBuild('Build', LConfig, LPlatform, LWarnings, LOutput);
      GBaselineWarnings.Add(PairKey(LConfig, LPlatform), LWarnings);
      if not LSuccess then begin
        Writeln('FAILED');
        PrintBuildOutputTail(LOutput);
        raise Exception.Create('The baseline build is invalid: the original project does not compile for ' + LConfig + '/' + LPlatform);
      end;
      if LWarnings.Count > 0 then begin
        Writeln(IntToStr(LWarnings.Count) + ' WARNING(S)');
        for I := 0 to LWarnings.Count - 1 do
          Writeln('    ' + LWarnings[I]);
        raise Exception.Create('The baseline build is invalid: the original project compiles with warnings for ' + LConfig + '/' + LPlatform);
      end;
      Writeln('OK');
    end;
end;

{*******************************************************************}
//we need this function for debuging because their is a bug in delphi
//that make we can not debug inlined var when they are inside the
//begin ... end of the dpr
procedure Kickoff;
begin

  try

    //Init project params
    {$IFDEF DEBUG}
    ReportMemoryleaksOnSHutdown := True;
    {$ENDIF}
    SetMultiByteConversionCodePage(CP_UTF8);

    Writeln('UsesCleaner - detects and removes unused units from uses clauses');
    Writeln('');

    {$REGION 'create local objects'}
    var LParamLst := TALStringListW.Create;
    var LPasFiles := TALStringListW.Create;
    var LSourceFiles := TObjectList<TSourceFile>.Create(True{AOwnsObjects});
    GBaselineWarnings := TObjectDictionary<String, TALStringListA>.Create([doOwnsValues]);
    {$ENDREGION}

    try

      {$REGION 'Init LParamLst'}
      for var I := 1 to ParamCount do
        LParamLst.Add(ParamStr(I));
      {$ENDREGION}

      {$REGION 'Init GProject'}
      GProject := Unquote(ALTrim(LParamLst.Values['-Project']));
      if GProject = '' then GProject := AskUser('Enter the path to the .dproj project file', '');
      if GProject = '' then raise Exception.Create('Project param is mandatory');
      GProject := ExpandFileName(GProject);
      if not TFile.Exists(GProject) then raise Exception.CreateFmt('Project file not found: %s', [GProject]);
      if not SameText(ExtractFileExt(GProject), '.dproj') then raise Exception.Create('The project file must be a .dproj file');
      GProjectDir := ExtractFilePath(GProject);
      {$ENDREGION}

      {$REGION 'Init LPasFiles'}
      LPasFiles.Sorted := True;
      LPasFiles.Duplicates := TDuplicates.dupIgnore;
      LPasFiles.CaseSensitive := False;
      var LSources := ALTrim(LParamLst.Values['-Sources']);
      if LSources = '' then LSources := AskUser('Enter the directories and/or *.pas files to process (separated by ";")', '');
      if LSources = '' then raise Exception.Create('Sources param is mandatory');
      for var LToken in SplitString(LSources, ';') do begin
        var LItem := Unquote(LToken);
        if LItem = '' then continue;
        if TDirectory.Exists(LItem) then begin
          for var LFileName in TDirectory.GetFiles(LItem, '*.pas', TSearchOption.soAllDirectories) do
            LPasFiles.Add(ExpandFileName(LFileName));
        end
        else if TFile.Exists(LItem) and SameText(ExtractFileExt(LItem), '.pas') then LPasFiles.Add(ExpandFileName(LItem))
        else raise Exception.CreateFmt('Directory or .pas file not found: %s', [LItem]);
      end;
      if LPasFiles.Count = 0 then raise Exception.Create('No .pas file found to process');
      {$ENDREGION}

      {$REGION 'Init GConfigs'}
      var LValue := ALTrim(LParamLst.Values['-Configs']);
      if LValue = '' then LValue := AskUser('Enter the build configuration(s) (separated by ";")', 'Debug;Release');
      GConfigs := SplitList(LValue);
      if Length(GConfigs) = 0 then raise Exception.Create('At least one build configuration is required');
      {$ENDREGION}

      {$REGION 'Init GPlatforms'}
      LValue := ALTrim(LParamLst.Values['-Platforms']);
      if LValue = '' then LValue := AskUser('Enter the target platform(s) (separated by ";")', 'Win32;Win64;Android64;iOSDevice64;OSXARM64');
      GPlatforms := SplitList(LValue);
      if Length(GPlatforms) = 0 then raise Exception.Create('At least one target platform is required');
      {$ENDREGION}

      {$REGION 'Init GRsVars'}
      GRsVars := Unquote(ALTrim(LParamLst.Values['-RsVars']));
      if GRsVars = '' then GRsVars := FindRsVars;
      if GRsVars = '' then GRsVars := AskUser('Enter the path to rsvars.bat (in the Delphi bin directory)', '');
      if (GRsVars = '') or (not TFile.Exists(GRsVars)) then raise Exception.CreateFmt('rsvars.bat not found: %s', [GRsVars]);
      {$ENDREGION}

      {$REGION 'Init options'}
      GCreateBackup := SameText(Trim(LParamLst.Values['-CreateBackup']), 'true');
      {$ENDREGION}

      {$REGION 'Check that no backup file already exists'}
      if GCreateBackup then
        for var I := 0 to LPasFiles.Count - 1 do
          if TFile.Exists(LPasFiles[I] + '.bak') then
            raise Exception.CreateFmt('The backup file (%s) already exists! Delete the existing .bak files first', [LPasFiles[I] + '.bak']);
      {$ENDREGION}

      Writeln('');
      Writeln('Project:        ' + GProject);
      Writeln('Configurations: ' + String.Join(';', GConfigs));
      Writeln('Platforms:      ' + String.Join(';', GPlatforms));
      Writeln('Files to scan:  ' + IntToStr(LPasFiles.Count));
      Writeln('');

      {$REGION 'Baseline builds'}
      Writeln('==== Baseline build ====');
      RunBaselineBuilds;
      Writeln('');
      {$ENDREGION}

      {$REGION 'Parse and normalize the uses clauses'}
      Writeln('==== Parsing and normalizing the uses clauses ====');
      var LNormalizedCount := 0;
      for var I := 0 to LPasFiles.Count - 1 do begin
        var LFilePath := LPasFiles[I];
        var LSource := ALGetStringFromFile(LFilePath);
        if ALPosA(#0, LSource) > 0 then begin
          Writeln('Skipped ' + LFilePath + ' (UTF-16 file not supported)');
          continue;
        end;
        var LSourceFile := TSourceFile.Create;
        LSourceFile.FilePath := LFilePath;
        LSourceFile.OriginalSource := LSource;
        try
          ParseSourceFile(LSource, LSourceFile);
        except
          on E: EUsesParseError do begin
            Writeln('Skipped ' + LFilePath + ' (' + E.Message + ')');
            ALFreeAndNil(LSourceFile);
            continue;
          end;
        end;
        LSourceFiles.Add(LSourceFile);
        var LNormalized := LSourceFile.GenerateSource;
        if LNormalized <> LSource then begin
          EnsureBackup(LSourceFile);
          ALSaveStringtoFile(LNormalized, LFilePath);
          LSourceFile.Modified := True;
          inc(LNormalizedCount);
          Writeln('Normalized ' + LFilePath);
        end;
      end;
      if LNormalizedCount > 0 then begin
        Writeln('Verifying that the normalization did not break the build ...');
        var LReason: String;
        if not TestBuildAllPairs(LReason) then begin
          for var LSourceFile in LSourceFiles do
            if LSourceFile.Modified then ALSaveStringtoFile(LSourceFile.OriginalSource, LSourceFile.FilePath);
          raise Exception.Create('The normalization of the uses clauses broke the build (' + LReason + '). All files have been restored.');
        end;
      end;
      Writeln('');
      {$ENDREGION}

      {$REGION 'Test the removal / move of each unit reference'}
      Writeln('==== Testing unit removals ====');
      for var LSourceFile in LSourceFiles do begin

        var LCandidateCount := 0;
        for var LClause in LSourceFile.Clauses do
          for var LItem in LClause.Items do
            if LItem.Kind = uikUnit then inc(LCandidateCount);
        if LCandidateCount = 0 then continue;

        Writeln('');
        Writeln(LSourceFile.FilePath);

        if not ProbeFileUsed(LSourceFile) then begin
          Writeln('  Skipped (the file is not compiled by any of the selected configurations/platforms)');
          continue;
        end;

        // Locate the implementation uses clause (can be a synthetic one)
        var LImplClause: TUsesClause := nil;
        for var LClause in LSourceFile.Clauses do
          if not LClause.IsInterface then LImplClause := LClause;

        // Tracks, for each guard signature, the first {$ENDIF} of the
        // conditional block already created in the implementation uses
        // clause so that units sharing the same guard are grouped together
        var LGuardBlocks := TDictionary<AnsiString, TUsesItem>.Create;
        try

          for var LClause in LSourceFile.Clauses do
            for var LItem in LClause.Items do begin
              if LItem.Kind <> uikUnit then continue;
              if LItem.MovedFromInterface then continue; // its removal was already tested from the interface clause
              if (LClause.ActiveUnitCount = 1) and LClause.HasDirectiveOrComment then begin
                Writeln('  ' + LItem.Text + ' ... kept (last unit of a clause containing compiler directives or comments)');
                continue;
              end;

              // First try to remove the unit reference
              LItem.Removed := True;
              SaveSourceFile(LSourceFile);
              Write('  ' + LItem.Text + ' ... ');
              var LReason: String;
              if TestBuildAllPairs(LReason) then begin
                ALWriteLN(String('REMOVED'), TALConsoleColor.ccGreen);
                continue;
              end;
              LItem.Removed := False;
              SaveSourceFile(LSourceFile);

              // Then, for a unit of the interface uses clause, try to
              // move it to the implementation uses clause
              if (not LClause.IsInterface) or
                 (LImplClause = nil) or
                 ClauseContainsActiveUnit(LImplClause, LItem.Text) then begin
                Writeln('kept (' + LReason + ')');
                continue;
              end;

              var LGuardPath := GetGuardPath(LClause, LItem);
              var LSignature := GuardSignature(LGuardPath);
              var LAppendedItems := TList<TUsesItem>.Create;
              try

                var LCreatedBlock := False;
                var LFirstEndif: TUsesItem := nil;
                var LMovedItem := TUsesItem.Create;
                LMovedItem.Kind := uikUnit;
                LMovedItem.Text := LItem.Text;
                LMovedItem.TrailingComment := LItem.TrailingComment;
                LMovedItem.MovedFromInterface := True;
                var LExistingEndif: TUsesItem;
                if Length(LGuardPath) = 0 then begin
                  LImplClause.Items.Add(LMovedItem);
                  LAppendedItems.Add(LMovedItem);
                end
                else if LGuardBlocks.TryGetValue(LSignature, LExistingEndif) and
                        (LImplClause.Items.IndexOf(LExistingEndif) >= 0) then begin
                  // Reuse the conditional block already created for this guard
                  LImplClause.Items.Insert(LImplClause.Items.IndexOf(LExistingEndif), LMovedItem);
                  LAppendedItems.Add(LMovedItem);
                end
                else begin
                  // Recreate the surrounding conditional compilation
                  // directives in the implementation uses clause
                  LCreatedBlock := True;
                  for var LDirective in LGuardPath do begin
                    var LDirectiveItem := TUsesItem.Create;
                    LDirectiveItem.Kind := uikDirective;
                    LDirectiveItem.Text := LDirective;
                    LImplClause.Items.Add(LDirectiveItem);
                    LAppendedItems.Add(LDirectiveItem);
                  end;
                  LImplClause.Items.Add(LMovedItem);
                  LAppendedItems.Add(LMovedItem);
                  for var J := 1 to CountOpeningDirectives(LGuardPath) do begin
                    var LEndifItem := TUsesItem.Create;
                    LEndifItem.Kind := uikDirective;
                    LEndifItem.Text := '{$ENDIF}';
                    LImplClause.Items.Add(LEndifItem);
                    LAppendedItems.Add(LEndifItem);
                    if LFirstEndif = nil then LFirstEndif := LEndifItem;
                  end;
                end;

                LItem.Removed := True; // hide it in the interface uses clause
                SaveSourceFile(LSourceFile);
                var LMoveReason: String;
                if TestBuildAllPairs(LMoveReason) then begin
                  if LCreatedBlock and (LFirstEndif <> nil) then LGuardBlocks.AddOrSetValue(LSignature, LFirstEndif);
                  ALWriteLN(String('MOVED to the implementation uses clause'), TALConsoleColor.ccGreen);
                end
                else begin
                  LItem.Removed := False;
                  for var LAppendedItem in LAppendedItems do
                    LImplClause.Items.Remove(LAppendedItem); // also frees the item (OwnsObjects)
                  SaveSourceFile(LSourceFile);
                  Writeln('kept (' + LReason + ')');
                end;

              finally
                ALFreeAndNil(LAppendedItems);
              end;

            end;

        finally
          ALFreeAndNil(LGuardBlocks);
        end;

      end;
      Writeln('');
      {$ENDREGION}

      {$REGION 'Final verification build'}
      Writeln('==== Final verification build ====');
      for var LConfig in GConfigs do
        for var LPlatform in GPlatforms do begin
          Write('Final build (' + LConfig + '/' + LPlatform + ') ... ');
          var LWarnings := CreateWarningList;
          try
            var LOutput: AnsiString;
            if not RunMSBuild('Build', LConfig, LPlatform, LWarnings, LOutput) then begin
              Writeln('FAILED');
              PrintBuildOutputTail(LOutput);
              raise Exception.Create('The final verification build failed for ' + LConfig + '/' + LPlatform);
            end;
            var LNewWarning := FirstNewWarning(GBaselineWarnings[PairKey(LConfig, LPlatform)], LWarnings);
            if LNewWarning <> '' then begin
              Writeln('FAILED');
              raise Exception.Create('The final verification build introduced a new warning for ' + LConfig + '/' + LPlatform + ': ' + String(LNewWarning));
            end;
            Writeln('OK');
          finally
            ALFreeAndNil(LWarnings);
          end;
        end;
      Writeln('');
      {$ENDREGION}

      Writeln('Finished');

    finally

      {$REGION 'Free local objects'}
      ALFreeAndNil(LParamLst);
      ALFreeAndNil(LPasFiles);
      ALFreeAndNil(LSourceFiles);
      ALFreeAndNil(GBaselineWarnings);
      {$ENDREGION}

    end;

    if GInteractive then begin
      Writeln('Press <Enter> key to quit');
      Readln;
    end;

  except
    on E: Exception do begin
      ALWriteLN(E.ClassName + ': ' + E.Message, TALConsoleColor.ccRed);
      Writeln('');
      Writeln('Usage:');
      Writeln('  UsesCleaner.exe');
      Writeln('    -Project=The path to the .dproj project file.');
      Writeln('    -Sources=The directories and/or *.pas files to process. Separate items with ";".');
      Writeln('    -Configs=The build configuration(s) to use. Default: Debug;Release');
      Writeln('    -Platforms=The target platform(s) to compile for. Default: Win32;Win64;Android64;iOSDevice64;OSXARM64');
      Writeln('    -RsVars=The path to rsvars.bat. Default: auto-detected from the registry.');
      Writeln('    -CreateBackup=true or false. Create a .bak file before modifying a file. Default: false');
      Writeln('');
      Writeln('  When a parameter is missing, the tool asks for it interactively.');
      Writeln('');
      Writeln('Example:');
      Writeln('  UsesCleaner.exe^');
      Writeln('    -Project="c:\MyProject\MyProject.dproj"^');
      Writeln('    -Sources="c:\MyProject\Source"^');
      Writeln('    -Configs="Debug;Release"^');
      Writeln('    -Platforms="Win32;Win64"');
      Writeln('');
      Writeln('');
      Writeln('UsesCleaner failed!');
      Writeln('Press <Enter> key to quit');
      Readln;
      halt(1);
    end;
  end;

end;

begin
  Kickoff;
end.
