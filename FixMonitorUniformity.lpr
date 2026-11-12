program FixMonitorUniformity;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  {$IFDEF HASAMIGA}
  athreads,
  {$ENDIF}
  Interfaces, // this includes the LCL widgetset
  Windows, Forms, Unit1
  { you can add units after this };

{$R *.res}

begin
  // Only one overlay per user session; the mutex is released by the OS when the process ends
  CreateMutex(nil, False, 'Local\FixMonitorUniformity.SingleInstance');
  if GetLastError = ERROR_ALREADY_EXISTS then
  begin
    MessageBox(0, 'FixMonitorUniformity is already running.', 'FixMonitorUniformity',
      MB_OK or MB_ICONINFORMATION);
    Exit;
  end;

  RequireDerivedFormResource:=True;
  Application.Scaled:=True;
  // Without this the hidden LCL application window gets its own taskbar button
  Application.MainFormOnTaskBar:=True;
  Application.Initialize;
  Application.CreateForm(TForm1, Form1);
  Application.Run;
end.

