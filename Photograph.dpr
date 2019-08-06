program Photograph;

{$R *.dres}

uses
  Vcl.Forms,
  Photo.Main in 'Photo.Main.pas' {FormMain};

{$R *.res}

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  {$IFDEF DEBUG}
  ReportMemoryLeaksOnShutdown := True;
  {$ENDIF}
  Application.CreateForm(TFormMain, FormMain);
  Application.Run;
end.
