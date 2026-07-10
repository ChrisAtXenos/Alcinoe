unit Alcinoe.FMX.Analytics;

{$I Alcinoe.inc}

interface

uses
  {$IF defined(android)}
  Alcinoe.AndroidApi.Firebase.Analytics,
  {$ENDIF}
  System.Net.URLClient;

type

  {***************************}
  TALAnalytics = class(Tobject)
  private
    class function CreateInstance: TALAnalytics;
    class function GetInstance: TALAnalytics; static;
  protected
    class var FInstance: TALAnalytics;
  public
    type
      TCreateInstanceFunc = function: TALAnalytics;
    class var CreateInstanceFunc: TCreateInstanceFunc;
    class property Instance: TALAnalytics read GetInstance;
    class function HasInstance: Boolean; inline;
  private

    {$REGION 'android'}
    {$IF defined(android)}
    fFirebaseAnalytics: JFirebaseAnalytics;
    {$ENDIF}
    {$ENDREGION}

  public
    constructor Create; virtual;
    procedure trackEvent(const AEventName: String); overload; virtual;
    procedure trackEvent(const AEventName: String; const AEventValues: TNameValueArray); overload; virtual;
    procedure TrackScreenView(const AScreenName: String; const AScreenClass: String); virtual;
    procedure SetUserID(const AUserID: Int64); virtual;
    procedure ClearUserID; virtual;
    procedure SetUserProperty(const APropertyName: String; const APropertyValue: String); virtual;
    procedure ClearUserProperty(const APropertyName: String); virtual;
  end;

implementation

uses
  System.SysUtils,
  {$IF defined(android)}
  Androidapi.JNI.JavaTypes,
  Androidapi.Helpers,
  Androidapi.JNI.Os,
  {$ENDIF}
  {$IF defined(ios)}
  Macapi.Helpers,
  Macapi.ObjectiveC,
  iOSapi.Foundation,
  // https://firebase.google.com/support/faq#analytics-adsupport-framework
  // Some Analytics features, such as audiences and campaign attribution,
  // and some user properties, such as age and interests, require the AdSupport
  // framework to be enabled. Without this framework, Analytics cannot collect
  // information needed for these features to function properly.
  Alcinoe.iOSApi.AdSupport, // UsesCleaner:keep
  Alcinoe.FMX.Firebase.Core,
  Alcinoe.iOSapi.FirebaseAnalytics,
  {$ENDIF}
  Alcinoe.StringUtils,
  Alcinoe.Common;

{******************************}
constructor TALAnalytics.Create;
begin

  inherited;

  {$REGION 'android'}
  {$IF defined(android)}
  fFirebaseAnalytics := TJFirebaseAnalytics.JavaClass.getInstance(TAndroidHelper.Context.getApplicationContext);
  {$ENDIF}
  {$ENDREGION}

  {$REGION 'ios'}
  {$IF defined(ios)}
  ALFIRAppConfigure;
  {$ENDIF}
  {$ENDREGION}

end;

{*******************************************************}
class function TALAnalytics.CreateInstance: TALAnalytics;
begin
  result := TALAnalytics.Create;
end;

{*************}
//[MultiThread]
class function TALAnalytics.GetInstance: TALAnalytics;
begin
  if FInstance = nil then begin
    var LInstance := CreateInstanceFunc;
    if AtomicCmpExchange(Pointer(FInstance), Pointer(LInstance), nil) <> nil then ALFreeAndNil(LInstance)
  end;
  Result := FInstance;
end;

{*************}
//[MultiThread]
class function TALAnalytics.HasInstance: Boolean;
begin
  result := FInstance <> nil;
end;

{**********************************************************}
procedure TALAnalytics.trackEvent(const AEventName: String);
begin

  {$IFDEF DEBUG}
  ALLog(Classname+'.trackEvent', 'EventName: ' + AEventName);
  if length(AEventName) > 40 then raise Exception.CreateFmt('Invalid Firebase Analytics event name "%s": maximum length is 40 characters, but it is %d characters long.', [AEventName, Length(AEventName)]);
  {$ENDIF}

  {$REGION 'android'}
  {$IF defined(android)}
  fFirebaseAnalytics.logEvent(StringToJString(aEventName), nil);
  {$ENDIF}
  {$ENDREGION}

  {$REGION 'ios'}
  {$IF defined(ios)}
  TFIRAnalytics.OCClass.logEventWithName(StrToNsStr(aEventName), nil);
  {$ENDIF}
  {$ENDREGION}

end;

{***********************************************************************************************}
procedure TALAnalytics.trackEvent(const AEventName: String; const AEventValues: TNameValueArray);
begin

  if length(AEventValues) = 0 then begin
    trackEvent(AEventName);
    exit;
  end;

  {$IFDEF DEBUG}
  var LEventValues: String := '';
  For var I := Low(AEventValues) to High(AEventValues) do
    LEventValues := LEventValues + ALIfThenW(LEventValues <> '', ',') + AEventValues[I].Name + '=' + AEventValues[I].Value;
  ALLog(Classname+'.trackEvent', 'EventName: ' + AEventName + ' | EventValues: ['+ LEventValues + ']');
  if length(AEventName) > 40 then raise Exception.CreateFmt('Invalid Firebase Analytics event name "%s": maximum length is 40 characters, but it is %d characters long.', [AEventName, Length(AEventName)]);
  {$ENDIF}

  {$REGION 'android'}
  {$IF defined(android)}
  var LBundle := TJBundle.JavaClass.init;
  for var I := Low(AEventValues) to High(AEventValues) do
    LBundle.putString(
      StringToJString(AEventValues[i].name),
      StringToJString(AEventValues[i].value));
  fFirebaseAnalytics.logEvent(StringToJString(AEventName), Lbundle);
  {$ENDIF}
  {$ENDREGION}

  {$REGION 'ios'}
  {$IF defined(ios)}
  var LObjects: array of pointer;
  var LForKeys: array of pointer;
  Setlength(LForKeys, length(AEventValues));
  Setlength(LObjects, length(AEventValues));
  for var I := Low(AEventValues) to High(AEventValues) do begin
    LForKeys[i] := (StrToNSStr(AEventValues[i].name) as ILocalObject).GetObjectID;
    LObjects[i] := (StrToNSStr(AEventValues[i].value) as ILocalObject).GetObjectID;
  end;
  var LParameters := TNSDictionary.Wrap(
                       TNSDictionary.OCClass.dictionaryWithObjects(
                         TNSArray.Wrap(TNSArray.OCClass.arrayWithObjects(@LObjects[0], Length(LObjects))),  // objects: NSArray;
                         TNSArray.Wrap(TNSArray.OCClass.arrayWithObjects(@LForKeys[0], Length(LForKeys))))); // forKeys: NSArray
  TFIRAnalytics.OCClass.logEventWithName(StrToNsStr(AEventName), LParameters);
  {$ENDIF}
  {$ENDREGION}

end;

{********************************************************************************************}
procedure TALAnalytics.TrackScreenView(const AScreenName: String; const AScreenClass: String);
begin
  // https://firebase.google.com/docs/analytics/screenviews
  // https://firebase.google.com/docs/reference/kotlin/com/google/firebase/analytics/FirebaseAnalytics.Param
  trackEvent(
    'screen_view',
    [TNameValuePair.Create('screen_name', AScreenName),
     TNameValuePair.Create('screen_class', AScreenClass)]);
end;

{*****************************************************}
procedure TALAnalytics.SetUserID(const AUserID: Int64);
begin

  {$IFDEF DEBUG}
  ALLog(Classname+'.SetUserID', 'UserID: ' + ALInttoStrW(AUserID));
  {$ENDIF}

  {$REGION 'android'}
  {$IF defined(android)}
  if aUserID <> 0 then fFirebaseAnalytics.setUserID(StringToJstring(ALIntToStrW(aUserID)))
  else ClearUserID;
  {$ENDIF}
  {$ENDREGION}

  {$REGION 'ios'}
  {$IF defined(ios)}
  if aUserID <> 0 then TFIRAnalytics.OCClass.setUserID(strToNSStr(ALIntToStrW(aUserID)))
  else ClearUserID;
  {$ENDIF}
  {$ENDREGION}

end;

{*********************************}
procedure TALAnalytics.ClearUserID;
begin

  {$IFDEF DEBUG}
  ALLog(Classname+'.ClearUserID');
  {$ENDIF}

  {$REGION 'android'}
  {$IF defined(android)}
  fFirebaseAnalytics.setUserID(nil);
  {$ENDIF}
  {$ENDREGION}

  {$REGION 'ios'}
  {$IF defined(ios)}
  TFIRAnalytics.OCClass.setUserID(nil);
  {$ENDIF}
  {$ENDREGION}

end;

{************************************************************************************************}
procedure TALAnalytics.SetUserProperty(const APropertyName: String; const APropertyValue: String);
begin
  {$IFDEF DEBUG}
  ALLog(Classname+'.SetUserProperty', 'PropertyName: ' + APropertyName + ' | PropertyValue: ' + APropertyValue);
  {$ENDIF}
end;

{********************************************************************}
procedure TALAnalytics.ClearUserProperty(const APropertyName: String);
begin
  {$IFDEF DEBUG}
  ALLog(Classname+'.ClearUserProperty', 'PropertyName: ' + APropertyName);
  {$ENDIF}
end;

initialization
  {$IF defined(DEBUG)}
  ALLog('Alcinoe.FMX.Analytics','initialization');
  {$ENDIF}
  TALAnalytics.FInstance := nil;
  TALAnalytics.CreateInstanceFunc := @TALAnalytics.CreateInstance;

finalization
  {$IF defined(DEBUG)}
  ALLog('Alcinoe.FMX.Analytics','finalization');
  {$ENDIF}
  ALFreeAndNil(TALAnalytics.FInstance);

end.