unit ZoneCorrection;

// Built-in mask generator: the user sets a dimming level for each zone of a 3x3 grid,
// the levels are blended smoothly between zone centres and dithered to 8-bit alpha.

{$mode objfpc}{$H+}

interface

uses
  Windows, Classes, SysUtils, Forms, Controls, Graphics, StdCtrls, ExtCtrls, Spin, Dialogs;

const
  ZoneCols = 3;
  ZoneRows = 3;
  ZoneCount = ZoneCols * ZoneRows;
  MaxZoneDimming = 50; // percent

type
  // Dimming in percent per zone, row by row from the top-left corner
  TZoneValues = array[0..ZoneCount - 1] of Double;
  // Overlay alpha per pixel, row by row from the top-left corner
  TAlphaPreviewEvent = procedure(const Alpha: TBytes; W, H: Integer) of object;

function GenerateZoneAlpha(const Zones: TZoneValues; W, H: Integer): TBytes;
procedure SaveAlphaAsMaskBmp(const FileName: string; const Alpha: TBytes; W, H: Integer);
function ReadBmpSize(const FileName: string; out W, H: Integer): Boolean;
// Shows the zone editor; the overlay is previewed live through OnPreview.
// Returns True and the new values when the user presses OK.
function EditZones(var Zones: TZoneValues; W, H: Integer; OnPreview: TAlphaPreviewEvent): Boolean;

implementation

// 8x8 Bayer matrix for ordered dithering
const
  Bayer8: array[0..7, 0..7] of Byte = (
    ( 0, 32,  8, 40,  2, 34, 10, 42),
    (48, 16, 56, 24, 50, 18, 58, 26),
    (12, 44,  4, 36, 14, 46,  6, 38),
    (60, 28, 52, 20, 62, 30, 54, 22),
    ( 3, 35, 11, 43,  1, 33,  9, 41),
    (51, 19, 59, 27, 49, 17, 57, 25),
    (15, 47,  7, 39, 13, 45,  5, 37),
    (63, 31, 55, 23, 61, 29, 53, 21));

type
  // Cubic Hermite basis for one pixel: segment between nodes K and K + 1
  THermite = record
    K: Integer;
    H00, H10, H01, H11: Double;
  end;

// Node i sits at the centre of zone i. Outside the outer centres the value is held constant.
function HermiteAt(Pixel, PixelCount, NodeCount: Integer): THermite;
var
  U, T, T2, T3: Double;
begin
  U := (Pixel + 0.5) * NodeCount / PixelCount - 0.5;
  if U < 0 then U := 0;
  if U > NodeCount - 1 then U := NodeCount - 1;
  Result.K := Trunc(U);
  if Result.K > NodeCount - 2 then Result.K := NodeCount - 2;
  T := U - Result.K;
  T2 := T * T;
  T3 := T2 * T;
  Result.H00 := 2 * T3 - 3 * T2 + 1;
  Result.H10 := T3 - 2 * T2 + T;
  Result.H01 := -2 * T3 + 3 * T2;
  Result.H11 := T3 - T2;
end;

// Slopes for monotone cubic interpolation (Fritsch-Butland) on unit-spaced nodes.
// The curve never overshoots the node values, so there are no dark or light rings.
// End slopes are zero to join the constant extension smoothly.
procedure PchipSlopes(const V: array of Double; var M: array of Double);
var
  i:      Integer;
  D0, D1: Double;
begin
  M[0] := 0;
  M[High(M)] := 0;
  for i := 1 to High(V) - 1 do
  begin
    D0 := V[i] - V[i - 1];
    D1 := V[i + 1] - V[i];
    if D0 * D1 <= 0 then
      M[i] := 0
    else
      M[i] := 2 * D0 * D1 / (D0 + D1);
  end;
end;

function GenerateZoneAlpha(const Zones: TZoneValues; W, H: Integer): TBytes;
var
  RowV, ColM: array of Double; // ZoneRows x W
  VX, MX:     array[0..ZoneCols - 1] of Double;
  VY, MY:     array[0..ZoneRows - 1] of Double;
  Hx, Hy:     THermite;
  X, Y, R, C, K, A: Integer;
  V:          Double;
begin
  Result := nil;
  SetLength(Result, W * H);
  SetLength(RowV, ZoneRows * W);
  SetLength(ColM, ZoneRows * W);

  // Interpolate horizontally through each row of zone centres
  for R := 0 to ZoneRows - 1 do
  begin
    for C := 0 to ZoneCols - 1 do
      VX[C] := Zones[R * ZoneCols + C] / 100;
    PchipSlopes(VX, MX);
    for X := 0 to W - 1 do
    begin
      Hx := HermiteAt(X, W, ZoneCols);
      RowV[R * W + X] := Hx.H00 * VX[Hx.K] + Hx.H10 * MX[Hx.K] + Hx.H01 * VX[Hx.K + 1] + Hx.H11 * MX[Hx.K + 1];
    end;
  end;

  // Vertical slopes for every pixel column
  for X := 0 to W - 1 do
  begin
    for R := 0 to ZoneRows - 1 do
      VY[R] := RowV[R * W + X];
    PchipSlopes(VY, MY);
    for R := 0 to ZoneRows - 1 do
      ColM[R * W + X] := MY[R];
  end;

  // Interpolate vertically and dither to 8-bit alpha. The threshold averages to the exact value,
  // so a gradient only a few alpha levels deep shows no bands.
  for Y := 0 to H - 1 do
  begin
    Hy := HermiteAt(Y, H, ZoneRows);
    K := Hy.K * W;
    for X := 0 to W - 1 do
    begin
      V := Hy.H00 * RowV[K + X] + Hy.H10 * ColM[K + X] + Hy.H01 * RowV[K + W + X] + Hy.H11 * ColM[K + W + X];
      A := Trunc(V * 255 + (Bayer8[Y and 7, X and 7] + 0.5) / 64);
      if A < 0 then A := 0;
      if A > 255 then A := 255;
      Result[Y * W + X] := A;
    end;
  end;
end;

// Writes an 8-bit grayscale BMP in the mask format: pixel value = 255 - alpha
procedure SaveAlphaAsMaskBmp(const FileName: string; const Alpha: TBytes; W, H: Integer);
var
  FileHdr: TBitmapFileHeader;
  InfoHdr: TBitmapInfoHeader;
  Palette: array[0..255] of TRGBQuad;
  Row:     TBytes;
  Stride, X, Y, i: Integer;
  Stream:  TFileStream;
begin
  Stride := (W + 3) and not 3;

  FillChar(InfoHdr, SizeOf(InfoHdr), 0);
  InfoHdr.biSize := SizeOf(InfoHdr);
  InfoHdr.biWidth := W;
  InfoHdr.biHeight := H; // bottom-up
  InfoHdr.biPlanes := 1;
  InfoHdr.biBitCount := 8;
  InfoHdr.biCompression := BI_RGB;
  InfoHdr.biSizeImage := Stride * H;
  InfoHdr.biClrUsed := 256;

  FillChar(FileHdr, SizeOf(FileHdr), 0);
  FileHdr.bfType := $4D42; // 'BM'
  FileHdr.bfOffBits := SizeOf(FileHdr) + SizeOf(InfoHdr) + SizeOf(Palette);
  FileHdr.bfSize := FileHdr.bfOffBits + InfoHdr.biSizeImage;

  for i := 0 to 255 do
  begin
    Palette[i].rgbBlue := i;
    Palette[i].rgbGreen := i;
    Palette[i].rgbRed := i;
    Palette[i].rgbReserved := 0;
  end;

  Row := nil;
  SetLength(Row, Stride);
  Stream := TFileStream.Create(FileName, fmCreate);
  try
    Stream.WriteBuffer(FileHdr, SizeOf(FileHdr));
    Stream.WriteBuffer(InfoHdr, SizeOf(InfoHdr));
    Stream.WriteBuffer(Palette, SizeOf(Palette));
    for Y := H - 1 downto 0 do
    begin
      for X := 0 to W - 1 do
        Row[X] := 255 - Alpha[Y * W + X];
      Stream.WriteBuffer(Row[0], Stride);
    end;
  finally
    Stream.Free;
  end;
end;

// Reads only the BMP header; False if the file is missing or isn't a BMP
function ReadBmpSize(const FileName: string; out W, H: Integer): Boolean;
var
  FileHdr: TBitmapFileHeader;
  InfoHdr: TBitmapInfoHeader;
  Stream:  TFileStream;
begin
  Result := False;
  W := 0;
  H := 0;
  if not FileExists(FileName) then Exit;
  try
    Stream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
    try
      Stream.ReadBuffer(FileHdr, SizeOf(FileHdr));
      Stream.ReadBuffer(InfoHdr, SizeOf(InfoHdr));
    finally
      Stream.Free;
    end;
  except
    Exit;
  end;
  if (FileHdr.bfType <> $4D42) or (InfoHdr.biSize < SizeOf(InfoHdr)) then Exit;
  W := InfoHdr.biWidth;
  H := Abs(InfoHdr.biHeight);
  Result := True;
end;

{ TZoneEditor }

type
  TZoneEditor = class(TForm)
  private
    FEdits:        array[0..ZoneCount - 1] of TFloatSpinEdit;
    FGrayCheck:    TCheckBox;
    FGrayLevel:    TSpinEdit;
    FGrayWindow:   TForm;
    FPreviewTimer: TTimer;
    FMaskW, FMaskH: Integer;
    FOnPreview:    TAlphaPreviewEvent;
    function AddRow(AOrder, AColumns: Integer): TPanel;
    procedure ValueChanged(Sender: TObject);
    procedure PreviewTimerTimer(Sender: TObject);
    procedure GrayChanged(Sender: TObject);
    procedure ResetClick(Sender: TObject);
    procedure ExportClick(Sender: TObject);
  public
    constructor CreateEditor(const Zones: TZoneValues; W, H: Integer; OnPreview: TAlphaPreviewEvent);
    destructor Destroy; override;
    function GetZones: TZoneValues;
  end;

// A borderless, auto-sized panel stacked under the previous ones, laying out its children in a grid
function TZoneEditor.AddRow(AOrder, AColumns: Integer): TPanel;
begin
  Result := TPanel.Create(Self);
  Result.Parent := Self;
  Result.BevelOuter := bvNone;
  Result.Top := AOrder * 1000; // alTop keeps the panels in this order
  Result.Align := alTop;
  Result.AutoSize := True;
  Result.BorderSpacing.Around := ScaleX(8, 96);
  Result.ChildSizing.Layout := cclLeftToRightThenTopToBottom;
  Result.ChildSizing.ControlsPerLine := AColumns;
  Result.ChildSizing.HorizontalSpacing := ScaleX(6, 96);
  Result.ChildSizing.VerticalSpacing := ScaleY(6, 96);
end;

constructor TZoneEditor.CreateEditor(const Zones: TZoneValues; W, H: Integer; OnPreview: TAlphaPreviewEvent);
var
  Panel:  TPanel;
  Lbl:    TLabel;
  Button: TButton;
  i:      Integer;
begin
  inherited CreateNew(nil);
  FMaskW := W;
  FMaskH := H;
  FOnPreview := OnPreview;
  Caption := 'Zone Correction';
  BorderStyle := bsDialog;
  Position := poScreenCenter;
  AutoSize := True;
  ShowInTaskBar := stAlways;

  Panel := AddRow(0, 1);
  Lbl := TLabel.Create(Self);
  Lbl.Caption := 'Dimming of each screen zone, %. The values apply to zone centres'#13#10
    + 'and blend smoothly between them. The overlay updates as you type.';
  Lbl.Parent := Panel;

  // Laid out like the screen: top row first
  Panel := AddRow(1, ZoneCols);
  Panel.BevelOuter := bvLowered;
  Panel.ChildSizing.LeftRightSpacing := ScaleX(10, 96);
  Panel.ChildSizing.TopBottomSpacing := ScaleY(10, 96);
  Panel.ChildSizing.HorizontalSpacing := ScaleX(24, 96);
  Panel.ChildSizing.VerticalSpacing := ScaleY(18, 96);
  for i := 0 to ZoneCount - 1 do
  begin
    FEdits[i] := TFloatSpinEdit.Create(Self);
    FEdits[i].MinValue := 0;
    FEdits[i].MaxValue := MaxZoneDimming;
    FEdits[i].Increment := 0.5;
    FEdits[i].DecimalPlaces := 1;
    FEdits[i].Width := ScaleX(80, 96);
    FEdits[i].Value := Zones[i];
    FEdits[i].Parent := Panel;
    FEdits[i].OnChange := @ValueChanged;
  end;

  Panel := AddRow(2, 3);
  FGrayCheck := TCheckBox.Create(Self);
  FGrayCheck.Caption := 'Uniform gray test background, brightness %:';
  FGrayCheck.Parent := Panel;
  FGrayCheck.OnChange := @GrayChanged;
  FGrayLevel := TSpinEdit.Create(Self);
  FGrayLevel.MinValue := 0;
  FGrayLevel.MaxValue := 100;
  FGrayLevel.Increment := 5;
  FGrayLevel.Value := 50;
  FGrayLevel.Width := ScaleX(60, 96);
  FGrayLevel.Parent := Panel;
  FGrayLevel.OnChange := @GrayChanged;

  Panel := AddRow(3, 4);
  Button := TButton.Create(Self);
  Button.Caption := 'Reset';
  Button.AutoSize := True;
  Button.Parent := Panel;
  Button.OnClick := @ResetClick;
  Button := TButton.Create(Self);
  Button.Caption := 'Save as BMP...';
  Button.AutoSize := True;
  Button.Parent := Panel;
  Button.OnClick := @ExportClick;
  Button := TButton.Create(Self);
  Button.Caption := 'OK';
  Button.Default := True;
  Button.ModalResult := mrOK;
  Button.Parent := Panel;
  Button := TButton.Create(Self);
  Button.Caption := 'Cancel';
  Button.Cancel := True;
  Button.ModalResult := mrCancel;
  Button.Parent := Panel;

  // Regenerating a full-screen mask takes a moment, so wait until typing pauses
  FPreviewTimer := TTimer.Create(Self);
  FPreviewTimer.Enabled := False;
  FPreviewTimer.Interval := 150;
  FPreviewTimer.OnTimer := @PreviewTimerTimer;
  PreviewTimerTimer(nil);
end;

destructor TZoneEditor.Destroy;
begin
  FGrayWindow.Free;
  inherited Destroy;
end;

function TZoneEditor.GetZones: TZoneValues;
var
  i: Integer;
begin
  for i := 0 to ZoneCount - 1 do
    Result[i] := FEdits[i].Value;
end;

procedure TZoneEditor.ValueChanged(Sender: TObject);
begin
  FPreviewTimer.Enabled := False;
  FPreviewTimer.Enabled := True;
end;

procedure TZoneEditor.PreviewTimerTimer(Sender: TObject);
begin
  FPreviewTimer.Enabled := False;
  if Assigned(FOnPreview) then
    FOnPreview(GenerateZoneAlpha(GetZones, FMaskW, FMaskH), FMaskW, FMaskH);
end;

// A plain gray screen under the overlay and this dialog shows the remaining unevenness best
procedure TZoneEditor.GrayChanged(Sender: TObject);
var
  G: Byte;
begin
  if FGrayCheck.Checked then
  begin
    G := Round(FGrayLevel.Value * 2.55);
    if FGrayWindow = nil then
    begin
      FGrayWindow := TForm.CreateNew(nil);
      FGrayWindow.BorderStyle := bsNone;
      FGrayWindow.ShowInTaskBar := stNever;
      FGrayWindow.SetBounds(0, 0, FMaskW, FMaskH);
    end;
    FGrayWindow.Color := RGBToColor(G, G, G);
    FGrayWindow.Invalidate;
    // Right below this dialog, without taking focus from it
    ShowWindow(FGrayWindow.Handle, SW_SHOWNOACTIVATE);
    SetWindowPos(FGrayWindow.Handle, Handle, 0, 0, 0, 0, SWP_NOMOVE or SWP_NOSIZE or SWP_NOACTIVATE);
  end
  else if FGrayWindow <> nil then
    ShowWindow(FGrayWindow.Handle, SW_HIDE);
end;

procedure TZoneEditor.ResetClick(Sender: TObject);
var
  i: Integer;
begin
  for i := 0 to ZoneCount - 1 do
    FEdits[i].Value := 0;
end;

procedure TZoneEditor.ExportClick(Sender: TObject);
var
  Dlg: TSaveDialog;
begin
  Dlg := TSaveDialog.Create(nil);
  try
    Dlg.Title := 'Save Correction Mask';
    Dlg.Filter := 'Bitmap files (*.bmp)|*.bmp';
    Dlg.DefaultExt := 'bmp';
    Dlg.Options := Dlg.Options + [ofOverwritePrompt];
    if Dlg.Execute then
      try
        SaveAlphaAsMaskBmp(Dlg.FileName, GenerateZoneAlpha(GetZones, FMaskW, FMaskH), FMaskW, FMaskH);
      except
        on E: Exception do
          MessageDlg('FixMonitorUniformity', 'Cannot save the mask:'#13#10 + E.Message, mtError, [mbOK], 0);
      end;
  finally
    Dlg.Free;
  end;
end;

function EditZones(var Zones: TZoneValues; W, H: Integer; OnPreview: TAlphaPreviewEvent): Boolean;
var
  Editor: TZoneEditor;
begin
  Editor := TZoneEditor.CreateEditor(Zones, W, H, OnPreview);
  try
    Result := Editor.ShowModal = mrOK;
    if Result then
      Zones := Editor.GetZones;
  finally
    Editor.Free;
  end;
end;

end.
