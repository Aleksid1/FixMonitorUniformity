unit Unit1;

{$mode objfpc}{$H+}

interface

uses
  Windows, LCLType, Classes, SysUtils, Forms, Controls, Graphics, Dialogs, ExtCtrls, Menus, IniFiles, WinDirs, Registry,
  LMessages, ZoneCorrection;

type

  { TForm1 }

  TForm1 = class(TForm)
    procedure FormCreate(Sender: TObject);
  private
    FFullscreenTimer: TTimer;
    FHiddenForFullscreen: Boolean;
    FTrayIcon: TTrayIcon;
    FTrayMenu: TPopupMenu;
    FAutostartItem: TMenuItem;
    FMaskFile: string;
    FEditingZones: Boolean;
    FDisplayChangeTimer: TTimer;
    procedure FullscreenTimerTimer(Sender: TObject);
    procedure DisplayChangeTimerTimer(Sender: TObject);
    procedure WMDisplayChange(var Msg: TLMessage); message WM_DISPLAYCHANGE;
    procedure SelectMaskMenuItemClick(Sender: TObject);
    procedure ZoneCorrectionMenuItemClick(Sender: TObject);
    procedure AutostartMenuItemClick(Sender: TObject);
    procedure TrayMenuPopup(Sender: TObject);
    procedure AboutMenuItemClick(Sender: TObject);
    procedure ExitMenuItemClick(Sender: TObject);
    procedure CreateTrayIcon;
    function ApplyMask(const FileName: string): Boolean;
    function SelectMask: Boolean;
    function ApplyZones(const Zones: TZoneValues): Boolean;
    function EditZoneCorrection: Boolean;
    function ChooseInitialMask: Boolean;
    procedure PreviewAlpha(const Alpha: TBytes; W, H: Integer);
  protected
    procedure CreateParams(var Params: TCreateParams); override;
    procedure DestroyWnd; override;
    procedure UpdateLayer(const MaskFile: string);
    procedure ShowAlpha(const Alpha: TBytes; W, H: Integer);
  end;

var
  Form1: TForm1;

implementation

{$R *.lfm}

// Not declared in the FPC 3.2 Windows unit
function UpdateLayeredWindow(hWnd: HWND; hdcDst: HDC; pptDst: PPoint; psize: PSize;
  hdcSrc: HDC; pptSrc: PPoint; crKey: COLORREF; pblend: PBlendFunction;
  dwFlags: DWORD): BOOL; stdcall; external user32 name 'UpdateLayeredWindow';

const
  QUNS_RUNNING_D3D_FULL_SCREEN = 3;

function SHQueryUserNotificationState(out pquns: Integer): HRESULT; stdcall;
  external 'shell32.dll' name 'SHQueryUserNotificationState';

const
  // Windows 10 2004+: the window is shown on screen but left out of screenshots and screen capture
  WDA_EXCLUDEFROMCAPTURE = $11;

function SetWindowDisplayAffinity(hWnd: HWND; dwAffinity: DWORD): BOOL; stdcall;
  external user32 name 'SetWindowDisplayAffinity';

const
  // Keep in sync with the version info in FixMonitorUniformity.lpi
  AppVersion = '1.0';
  AppYear = '2026';
  AppUrl = 'https://github.com/Aleksid1/FixMonitorUniformity';

  ExStyleFlags = WS_EX_TOPMOST or WS_EX_TRANSPARENT or WS_EX_LAYERED or WS_EX_TOOLWINDOW;

  ConfigSection = 'Settings';
  ConfigMaskKey = 'MaskFile';
  ZonesSection = 'Zones';

// Per-user, per-machine settings: %LOCALAPPDATA%\FixMonitorUniformity\FixMonitorUniformity.ini.
// Local rather than roaming AppData because the mask is made for a specific physical monitor.
function ConfigFileName: string;
begin
  Result := IncludeTrailingPathDelimiter(GetWindowsSpecialDir(CSIDL_LOCAL_APPDATA))
    + 'FixMonitorUniformity\FixMonitorUniformity.ini';
end;

function LoadMaskPath: string;
var
  Ini: TIniFile;
begin
  Ini := TIniFile.Create(ConfigFileName);
  try
    Result := Ini.ReadString(ConfigSection, ConfigMaskKey, '');
  finally
    Ini.Free;
  end;
end;

procedure SaveMaskPath(const MaskFile: string);
var
  Ini: TIniFile;
begin
  ForceDirectories(ExtractFileDir(ConfigFileName));
  Ini := TIniFile.Create(ConfigFileName);
  try
    Ini.WriteString(ConfigSection, ConfigMaskKey, MaskFile);
  finally
    Ini.Free;
  end;
end;

// The zone mask is generated once, when the user confirms the zone editor, and then loaded like any mask
function ZoneMaskFileName: string;
begin
  Result := ExtractFilePath(ConfigFileName) + 'ZoneMask.bmp';
end;

// Primary monitor size in physical pixels (the program is DPI-aware)
function PrimaryScreenSize: TSize;
begin
  Result.cx := GetSystemMetrics(SM_CXSCREEN);
  Result.cy := GetSystemMetrics(SM_CYSCREEN);
end;

function IniFormat: TFormatSettings;
begin
  Result := DefaultFormatSettings;
  Result.DecimalSeparator := '.';
end;

function LoadZones: TZoneValues;
var
  Ini: TIniFile;
  i:   Integer;
begin
  Ini := TIniFile.Create(ConfigFileName);
  try
    for i := 0 to ZoneCount - 1 do
    begin
      Result[i] := StrToFloatDef(Ini.ReadString(ZonesSection, 'Zone' + IntToStr(i + 1), '0'), 0, IniFormat);
      if Result[i] < 0 then Result[i] := 0;
      if Result[i] > MaxZoneDimming then Result[i] := MaxZoneDimming;
    end;
  finally
    Ini.Free;
  end;
end;

procedure SaveZones(const Zones: TZoneValues);
var
  Ini: TIniFile;
  i:   Integer;
begin
  ForceDirectories(ExtractFileDir(ConfigFileName));
  Ini := TIniFile.Create(ConfigFileName);
  try
    for i := 0 to ZoneCount - 1 do
      Ini.WriteString(ZonesSection, 'Zone' + IntToStr(i + 1), FloatToStr(Zones[i], IniFormat));
  finally
    Ini.Free;
  end;
end;

// The cached zone mask is used as is unless it's missing or the screen resolution has changed
function ZoneMaskIsCurrent: Boolean;
var
  W, H: Integer;
begin
  Result := ReadBmpSize(ZoneMaskFileName, W, H) and (W = PrimaryScreenSize.cx) and (H = PrimaryScreenSize.cy);
end;

const
  RunKey = 'Software\Microsoft\Windows\CurrentVersion\Run';
  // Windows 8+ keeps the Task Manager "Startup" enabled/disabled state here, separately from the Run value
  StartupApprovedKey = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run';
  AutostartValueName = 'FixMonitorUniformity';

function AutostartCommand: string;
begin
  Result := '"' + Application.ExeName + '"';
end;

// Command line in the per-user Run key, or '' if there is none
function ReadAutostartCommand: string;
var
  Reg: TRegistry;
begin
  Result := '';
  Reg := TRegistry.Create(KEY_READ);
  try
    Reg.RootKey := HKEY_CURRENT_USER;
    if Reg.OpenKeyReadOnly(RunKey) and Reg.ValueExists(AutostartValueName) then
      Result := Reg.ReadString(AutostartValueName);
  finally
    Reg.Free;
  end;
end;

// True when the Run value exists and isn't disabled in Task Manager
function IsAutostartEnabled: Boolean;
var
  Reg:  TRegistry;
  Data: array of Byte;
  Size: Integer;
begin
  Result := ReadAutostartCommand <> '';
  if not Result then Exit;
  Reg := TRegistry.Create(KEY_READ);
  try
    Reg.RootKey := HKEY_CURRENT_USER;
    if Reg.OpenKeyReadOnly(StartupApprovedKey) and Reg.ValueExists(AutostartValueName) then
    begin
      Size := Reg.GetDataSize(AutostartValueName);
      if Size > 0 then
      begin
        SetLength(Data, Size);
        // The first byte is even when enabled (02) and odd when disabled (03)
        if Reg.ReadBinaryData(AutostartValueName, Data[0], Size) > 0 then
          Result := not Odd(Data[0]);
      end;
    end;
  finally
    Reg.Free;
  end;
end;

procedure SetAutostart(Enable: Boolean);
var
  Reg: TRegistry;
begin
  Reg := TRegistry.Create(KEY_READ or KEY_WRITE);
  try
    Reg.RootKey := HKEY_CURRENT_USER;
    if not Reg.OpenKey(RunKey, True) then
      raise ERegistryException.Create('Cannot open registry key HKCU\' + RunKey);
    if Enable then
      Reg.WriteString(AutostartValueName, AutostartCommand)
    else if Reg.ValueExists(AutostartValueName) then
      Reg.DeleteValue(AutostartValueName);
    Reg.CloseKey;
    // Drop a Task Manager "disabled" mark, otherwise it would keep overriding the Run value
    if Reg.OpenKey(StartupApprovedKey, False) and Reg.ValueExists(AutostartValueName) then
      Reg.DeleteValue(AutostartValueName);
  finally
    Reg.Free;
  end;
end;

procedure TForm1.CreateParams(var Params: TCreateParams);
begin
  inherited CreateParams(Params);
  Params.Style := WS_POPUP;
  Params.ExStyle := ExStyleFlags;
end;

procedure TForm1.DestroyWnd;
begin
  // Window properties must be removed before the window is destroyed
  RemoveProp(Handle, 'NonRudeHWND');
  inherited DestroyWnd;
end;

procedure TForm1.FormCreate(Sender: TObject);
var
  MaskLoaded: Boolean;
begin
  // LCL may recompute window styles from BorderStyle/FormStyle, so enforce them on the real handle
  SetWindowLongPtr(Handle, GWL_EXSTYLE, GetWindowLongPtr(Handle, GWL_EXSTYLE) or ExStyleFlags);
  // A topmost window covering the whole monitor is treated by Explorer as a "rude" fullscreen app:
  // the taskbar then drops its own WS_EX_TOPMOST and ordinary windows can cover it.
  // This shell property excludes our overlay from that fullscreen detection.
  SetProp(Handle, 'NonRudeHWND', 1);
  // Keep the overlay out of PrintScreen and other screen captures.
  // Fails on Windows before 10 2004; the overlay is then captured as before.
  // WDA_MONITOR is not a fallback: it would blacken the whole overlay in captures.
  SetWindowDisplayAffinity(Handle, WDA_EXCLUDEFROMCAPTURE);

  // Use the remembered mask; ask for one if there is none or it can't be loaded.
  // The zone mask is regenerated from the saved zone values only if it's missing or doesn't fit the screen.
  FMaskFile := LoadMaskPath;
  if (FMaskFile <> '') and SameText(FMaskFile, ZoneMaskFileName) and not ZoneMaskIsCurrent then
    MaskLoaded := ApplyZones(LoadZones)
  else
    MaskLoaded := (FMaskFile <> '') and FileExists(FMaskFile) and ApplyMask(FMaskFile);
  if not MaskLoaded and not ChooseInitialMask then
  begin
    // No mask, nothing to correct
    Application.ShowMainForm := False;
    Application.Terminate;
    Exit;
  end;

  // Hide the overlay while an exclusive fullscreen Direct3D app runs,
  // so the game keeps direct (non-composed) output
  FFullscreenTimer := TTimer.Create(Self);
  FFullscreenTimer.Interval := 3000;
  FFullscreenTimer.OnTimer := @FullscreenTimerTimer;

  // A resolution change usually arrives as several WM_DISPLAYCHANGE messages; react once they settle
  FDisplayChangeTimer := TTimer.Create(Self);
  FDisplayChangeTimer.Enabled := False;
  FDisplayChangeTimer.Interval := 500;
  FDisplayChangeTimer.OnTimer := @DisplayChangeTimerTimer;

  // Keep autostart pointing at this exe if the program has been moved
  try
    if (ReadAutostartCommand <> '') and not SameText(ReadAutostartCommand, AutostartCommand) then
      SetAutostart(True);
  except
    // Not critical: the user can re-enable autostart from the tray menu
  end;

  CreateTrayIcon;
end;

procedure TForm1.CreateTrayIcon;
var
  Item: TMenuItem;
begin
  FTrayMenu := TPopupMenu.Create(Self);
  FTrayMenu.OnPopup := @TrayMenuPopup;
  Item := TMenuItem.Create(FTrayMenu);
  Item.Caption := 'Select Mask...';
  Item.OnClick := @SelectMaskMenuItemClick;
  FTrayMenu.Items.Add(Item);
  Item := TMenuItem.Create(FTrayMenu);
  Item.Caption := 'Zone Correction...';
  Item.OnClick := @ZoneCorrectionMenuItemClick;
  FTrayMenu.Items.Add(Item);
  Item := TMenuItem.Create(FTrayMenu);
  Item.Caption := '-';
  FTrayMenu.Items.Add(Item);
  FAutostartItem := TMenuItem.Create(FTrayMenu);
  FAutostartItem.Caption := 'Start with Windows';
  FAutostartItem.OnClick := @AutostartMenuItemClick;
  FTrayMenu.Items.Add(FAutostartItem);
  Item := TMenuItem.Create(FTrayMenu);
  Item.Caption := '-';
  FTrayMenu.Items.Add(Item);
  Item := TMenuItem.Create(FTrayMenu);
  Item.Caption := 'About...';
  Item.OnClick := @AboutMenuItemClick;
  FTrayMenu.Items.Add(Item);
  Item := TMenuItem.Create(FTrayMenu);
  Item.Caption := '-';
  FTrayMenu.Items.Add(Item);
  Item := TMenuItem.Create(FTrayMenu);
  Item.Caption := 'Exit';
  Item.OnClick := @ExitMenuItemClick;
  FTrayMenu.Items.Add(Item);

  FTrayIcon := TTrayIcon.Create(Self);
  FTrayIcon.Icon.Assign(Application.Icon);
  FTrayIcon.Hint := 'FixMonitorUniformity';
  FTrayIcon.PopUpMenu := FTrayMenu;
  FTrayIcon.Visible := True;
end;

procedure TForm1.SelectMaskMenuItemClick(Sender: TObject);
begin
  SelectMask;
end;

procedure TForm1.ZoneCorrectionMenuItemClick(Sender: TObject);
begin
  EditZoneCorrection;
end;

// The check mark is read from the registry on every popup, so changes made in Task Manager show up
procedure TForm1.TrayMenuPopup(Sender: TObject);
var
  i: Integer;
begin
  FAutostartItem.Checked := IsAutostartEnabled;
  // The tray menu stays reachable while the zone editor is open; keep it from re-entering
  for i := 0 to FTrayMenu.Items.Count - 1 do
    FTrayMenu.Items[i].Enabled := not FEditingZones;
end;

procedure TForm1.AutostartMenuItemClick(Sender: TObject);
begin
  try
    SetAutostart(not IsAutostartEnabled);
  except
    on E: Exception do
      MessageDlg('FixMonitorUniformity', 'Cannot change autostart:'#13#10 + E.Message, mtError, [mbOK], 0);
  end;
end;

procedure TForm1.AboutMenuItemClick(Sender: TObject);
begin
  MessageDlg('About FixMonitorUniformity',
    'FixMonitorUniformity ' + AppVersion + #13#10
    + 'Copyright (c) ' + AppYear + #13#10#13#10
    + 'Corrects uneven monitor backlighting in software.'#13#10
    + 'Free and open source software, MIT License.'#13#10#13#10
    + AppUrl,
    mtInformation, [mbOK], 0);
end;

procedure TForm1.ExitMenuItemClick(Sender: TObject);
begin
  Close;
end;

// Loads the mask into the overlay and remembers it; on failure the current overlay stays as is
function TForm1.ApplyMask(const FileName: string): Boolean;
begin
  try
    UpdateLayer(FileName);
  except
    on E: Exception do
    begin
      MessageDlg('FixMonitorUniformity', Format('Cannot load mask "%s":'#13#10'%s', [FileName, E.Message]),
        mtError, [mbOK], 0);
      Exit(False);
    end;
  end;
  FMaskFile := FileName;
  SaveMaskPath(FileName);
  Result := True;
end;

// Asks for a mask file until one loads or the user cancels
function TForm1.SelectMask: Boolean;
var
  Dlg: TOpenDialog;
begin
  Result := False;
  Dlg := TOpenDialog.Create(nil);
  try
    Dlg.Title := 'Select Correction Mask';
    Dlg.Filter := 'Bitmap files (*.bmp)|*.bmp|All files (*.*)|*.*';
    Dlg.Options := Dlg.Options + [ofFileMustExist];
    if FMaskFile <> '' then
    begin
      Dlg.InitialDir := ExtractFileDir(FMaskFile);
      Dlg.FileName := ExtractFileName(FMaskFile);
    end;
    while Dlg.Execute do
      if ApplyMask(Dlg.FileName) then
        Exit(True);
  finally
    Dlg.Free;
  end;
end;

// Generates the zone mask, caches it as a BMP and shows it; on failure the current overlay stays as is
function TForm1.ApplyZones(const Zones: TZoneValues): Boolean;
var
  Alpha: TBytes;
  Size:  TSize;
begin
  Size := PrimaryScreenSize;
  try
    Alpha := GenerateZoneAlpha(Zones, Size.cx, Size.cy);
    ForceDirectories(ExtractFileDir(ZoneMaskFileName));
    SaveAlphaAsMaskBmp(ZoneMaskFileName, Alpha, Size.cx, Size.cy);
    ShowAlpha(Alpha, Size.cx, Size.cy);
  except
    on E: Exception do
    begin
      MessageDlg('FixMonitorUniformity', 'Cannot create the zone mask:'#13#10 + E.Message, mtError, [mbOK], 0);
      Exit(False);
    end;
  end;
  SaveZones(Zones);
  FMaskFile := ZoneMaskFileName;
  SaveMaskPath(FMaskFile);
  Result := True;
end;

// Opens the zone editor with the saved values; the overlay previews them live
function TForm1.EditZoneCorrection: Boolean;
var
  Zones: TZoneValues;
  Size:  TSize;
begin
  Result := False;
  Zones := LoadZones;
  Size := PrimaryScreenSize;
  FEditingZones := True;
  try
    if EditZones(Zones, Size.cx, Size.cy, @PreviewAlpha) then
      Result := ApplyZones(Zones);
  finally
    FEditingZones := False;
  end;
  if Result then Exit;
  // Cancelled or failed: bring back the previous mask, or no overlay at all at first start
  if FMaskFile = '' then
    ShowWindow(Handle, SW_HIDE)
  else if SameText(FMaskFile, ZoneMaskFileName) and not ZoneMaskIsCurrent then
    // The resolution changed while the editor was open: rebuild the saved zones for it
    ApplyZones(LoadZones)
  else
    try
      UpdateLayer(FMaskFile);
    except
      ShowWindow(Handle, SW_HIDE);
    end;
end;

// At first start (or when the remembered mask can't be loaded): zone correction or a mask file.
// Returns False if the user chooses to exit.
function TForm1.ChooseInitialMask: Boolean;
begin
  Result := True;
  repeat
    case QuestionDlg('FixMonitorUniformity',
      'Choose how to correct the monitor brightness:'#13#10#13#10
      + 'Zone Correction: set the dimming for each of 9 screen zones.'#13#10
      + 'Mask File: load a grayscale BMP mask.',
      mtConfirmation, [mrYes, 'Zone Correction...', mrNo, 'Mask File...', mrCancel, 'Exit'], 0) of
      mrYes:
        if EditZoneCorrection then Exit;
      mrNo:
        if SelectMask then Exit;
    else
      Exit(False);
    end;
  until False;
end;

// Live preview from the zone editor; at first start the overlay isn't shown yet
procedure TForm1.PreviewAlpha(const Alpha: TBytes; W, H: Integer);
begin
  ShowAlpha(Alpha, W, H);
  if not IsWindowVisible(Handle) then
    ShowWindow(Handle, SW_SHOWNOACTIVATE);
end;

procedure TForm1.WMDisplayChange(var Msg: TLMessage);
begin
  inherited;
  // Not created yet while FormCreate is still choosing the mask
  if FDisplayChangeTimer = nil then Exit;
  FDisplayChangeTimer.Enabled := False;
  FDisplayChangeTimer.Enabled := True;
end;

// The zone mask is regenerated for the new resolution and the cache is updated.
// A mask file is left as is: it was drawn for a specific resolution.
procedure TForm1.DisplayChangeTimerTimer(Sender: TObject);
begin
  FDisplayChangeTimer.Enabled := False;
  // The zone editor applies the current resolution itself when the user presses OK
  if FEditingZones then Exit;
  if SameText(FMaskFile, ZoneMaskFileName) and not ZoneMaskIsCurrent then
    ApplyZones(LoadZones);
end;

procedure TForm1.FullscreenTimerTimer(Sender: TObject);
var
  State:     Integer;
  IsD3DFull: Boolean;
begin
  IsD3DFull := (SHQueryUserNotificationState(State) = S_OK) and (State = QUNS_RUNNING_D3D_FULL_SCREEN);
  if IsD3DFull = FHiddenForFullscreen then Exit;
  FHiddenForFullscreen := IsD3DFull;
  // Plain WinAPI instead of Visible: LCL Show would try to activate the window
  if IsD3DFull then
    ShowWindow(Handle, SW_HIDE)
  else
  begin
    ShowWindow(Handle, SW_SHOWNOACTIVATE);
    SetWindowPos(Handle, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE or SWP_NOSIZE or SWP_NOACTIVATE);
  end;
end;

// Loads the mask; overlay alpha = 255 - blue channel
procedure TForm1.UpdateLayer(const MaskFile: string);
var
  Mask:      TBitmap;
  W, H, i:   Integer;
  ScreenDC:  HDC;
  BmpInfo:   Windows.TBitmapInfo;
  SrcPixels: array of TRGBQuad;
  Alpha:     TBytes;
begin
  Mask := TBitmap.Create;
  try
    Mask.LoadFromFile(MaskFile);
    W := Mask.Width;
    H := Mask.Height;

    FillChar(BmpInfo, SizeOf(BmpInfo), 0);
    BmpInfo.bmiHeader.biSize := SizeOf(BmpInfo.bmiHeader);
    BmpInfo.bmiHeader.biWidth := W;
    BmpInfo.bmiHeader.biHeight := -H; // top-down
    BmpInfo.bmiHeader.biPlanes := 1;
    BmpInfo.bmiHeader.biBitCount := 32;
    BmpInfo.bmiHeader.biCompression := BI_RGB;

    SetLength(SrcPixels, W * H);
    ScreenDC := GetDC(0);
    try
      GetDIBits(ScreenDC, Mask.Handle, 0, H, @SrcPixels[0], BmpInfo, DIB_RGB_COLORS);
    finally
      ReleaseDC(0, ScreenDC);
    end;
  finally
    Mask.Free;
  end;

  Alpha := nil;
  SetLength(Alpha, W * H);
  for i := 0 to W * H - 1 do
    Alpha[i] := 255 - SrcPixels[i].rgbBlue;
  SrcPixels := nil;
  ShowAlpha(Alpha, W, H);
end;

// Shows a black 32-bit premultiplied layer with the given per-pixel alpha at (0, 0)
procedure TForm1.ShowAlpha(const Alpha: TBytes; W, H: Integer);
var
  i:          Integer;
  ScreenDC:   HDC;
  MemDC:      HDC;
  BmpInfo:    Windows.TBitmapInfo;
  DstBits:    Pointer;
  Dst:        PDWord;
  DIB, OldBmp: HBITMAP;
  Blend:      Windows.TBlendFunction;
  DstPos, SrcPos: TPoint;
  Size:       TSize;
begin
  FillChar(BmpInfo, SizeOf(BmpInfo), 0);
  BmpInfo.bmiHeader.biSize := SizeOf(BmpInfo.bmiHeader);
  BmpInfo.bmiHeader.biWidth := W;
  BmpInfo.bmiHeader.biHeight := -H; // top-down
  BmpInfo.bmiHeader.biPlanes := 1;
  BmpInfo.bmiHeader.biBitCount := 32;
  BmpInfo.bmiHeader.biCompression := BI_RGB;

  ScreenDC := GetDC(0);
  try
    DIB := CreateDIBSection(ScreenDC, BmpInfo, DIB_RGB_COLORS, DstBits, 0, 0);
    if DIB = 0 then RaiseLastOSError;
    // Black premultiplied by any alpha stays black, so only the alpha byte is set
    Dst := DstBits;
    for i := 0 to W * H - 1 do
    begin
      Dst^ := DWord(Alpha[i]) shl 24;
      Inc(Dst);
    end;

    MemDC := CreateCompatibleDC(ScreenDC);
    OldBmp := SelectObject(MemDC, DIB);
    try
      Blend.BlendOp := AC_SRC_OVER;
      Blend.BlendFlags := 0;
      Blend.SourceConstantAlpha := 255;
      Blend.AlphaFormat := AC_SRC_ALPHA;
      DstPos := Point(0, 0);
      SrcPos := Point(0, 0);
      Size.cx := W;
      Size.cy := H;
      SetBounds(0, 0, W, H);
      UpdateLayeredWindow(Handle, ScreenDC, @DstPos, @Size, MemDC, @SrcPos, 0, @Blend, ULW_ALPHA);
    finally
      SelectObject(MemDC, OldBmp);
      DeleteDC(MemDC);
      DeleteObject(DIB);
    end;
  finally
    ReleaseDC(0, ScreenDC);
  end;
end;

end.
