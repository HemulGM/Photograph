unit Photo.Main;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants,
  System.Classes, Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Dialogs,
  directshow9, ActiveX, Jpeg, WinInet, IniFiles, Vcl.StdCtrls, Vcl.ExtCtrls,
  System.Generics.Collections, acPNG, HGM.Controls.PanelExt, HGM.Button,
  System.ImageList, Vcl.ImgList;

type
  TFormMain = class(TForm, ISampleGrabberCB)
    ListBoxCams: TListBox;
    DrawPanel1: TDrawPanel;
    Panel1: TPanel;
    ButtonFlatPhoto: TButtonFlat;
    ImageLastPhoto: TImage;
    ButtonFlatPorps: TButtonFlat;
    ImageList24: TImageList;
    ButtonFlatTurn: TButtonFlat;
    Panel2: TPanel;
    ButtonFlatFlash: TButtonFlat;
    ButtonFlatChangeCam: TButtonFlat;
    procedure ListBox1DblClick(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure DrawPanel1Paint(Sender: TObject);
    procedure ButtonFlatPhotoClick(Sender: TObject);
    procedure ButtonFlatPorpsClick(Sender: TObject);
    procedure ButtonFlatTurnClick(Sender: TObject);
    procedure ButtonFlatFlashClick(Sender: TObject);
    procedure ButtonFlatChangeCamClick(Sender: TObject);
    procedure ImageLastPhotoClick(Sender: TObject);
  private
    IniFile: TIniFile;
    Monikers: TList<IMoniker>;
    Bitmap: TBitmap;
    FAppClosing: Boolean;
    DoPhoto: Boolean;
    FDoFlash: Boolean;
    FSavePath: string;
    FLastFileName: string;
    //Интерфейсы
    FCaptureGraphBuilder: ICaptureGraphBuilder2;
    FMediaControl: IMediaControl;
    FVideoCaptureFilter: IBaseFilter;
    FSampleGrabber: ISampleGrabber;
    function SampleCB(SampleTime: Double; pSample: IMediaSample): HResult; stdcall;
    function BufferCB(SampleTime: Double; pBuffer: PByte; BufferLen: longint): HResult; stdcall;
    function CreatePhoto: TJPEGImage;
    function CreateGraph(Moniker: IMoniker): HResult;
    function CamsInit: HResult;
    function GetPhotoFileName(const Path: string): string;
    function SelectSavePath(var Path: string): Boolean;
  public
    procedure LoadSettings;
    procedure SaveSettings;
  end;

var
  FormMain: TFormMain;

implementation

uses
  Math, HGM.Common.Utils, ShellApi;

{$R *.dfm}

function TFormMain.CamsInit: HResult;
var
  DevEnum: ICreateDEvEnum;
  Moniker: IMoniker;
  Enum: IEnumMoniker;
  DeviceName: OleVariant;
  PropertyName: IPropertyBag;
begin
  //Создаем объект для перечисления устройств
  Result := CoCreateInstance(CLSID_SystemDeviceEnum, nil, CLSCTX_INPROC_SERVER, IID_ICreateDevEnum, DevEnum);
  if Result <> S_OK then
    Exit;
  //Перечислитель устройств Video
  Result := DevEnum.CreateClassEnumerator(CLSID_VideoInputDeviceCategory, Enum, 0);
  DevEnum := nil;
  if Result <> S_OK then
    Exit;
  Monikers.Clear;
  while (S_OK = Enum.Next(1, Moniker, nil)) do
  begin
    Monikers.Add(Moniker);
    Result := Moniker.BindToStorage(nil, nil, IPropertyBag, PropertyName);
    Moniker := nil;
    if FAILED(Result) then
      Continue;
    //Получаем имя устройства
    Result := PropertyName.Read('FriendlyName', DeviceName, nil);
    if FAILED(Result) then
      Continue;
    //Добавляем имя устройства в списки
    ListBoxCams.Items.Add(DeviceName);
  end;
  Enum := nil;
  PropertyName := nil;
  DeviceName := Unassigned;
  //Выбираем первую из спика камеру
  if ListBoxCams.Count = 0 then
  begin
    ShowMessage('Камера не обнаружена');
    Result := E_FAIL;
    Exit;
  end;
  ListBoxCams.ItemIndex := 0;
  Result := S_OK;
end;

function TFormMain.CreateGraph(Moniker: IMoniker): HResult;
var
  MediaType: AM_MEDIA_TYPE;
  FBaseFilter: IBaseFilter;
  FVideoRect: TRect;
  FVideoWindow: IVideoWindow;
  BasicVideo: IBasicVideo;
  FGraphBuilder: IGraphBuilder;
  wd: Integer;
begin
  FVideoCaptureFilter := nil;
  FMediaControl := nil;
  FSampleGrabber := nil;
  FCaptureGraphBuilder := nil;

  //Создаем объект для графа фильтров
  Result := CoCreateInstance(CLSID_FilterGraph, nil, CLSCTX_INPROC_SERVER, IID_IGraphBuilder, FGraphBuilder);
  if FAILED(Result) then
    Exit;
  //Создаем объект для граббинга
  Result := CoCreateInstance(CLSID_SampleGrabber, nil, CLSCTX_INPROC_SERVER, IID_IBaseFilter, FBaseFilter);
  if FAILED(Result) then
    Exit;
  //Создаем объект для графа захвата
  Result := CoCreateInstance(CLSID_CaptureGraphBuilder2, nil, CLSCTX_INPROC_SERVER, IID_ICaptureGraphBuilder2, FCaptureGraphBuilder);
  if FAILED(Result) then
    Exit;
  //Добавляем фильтр в граф
  Result := FGraphBuilder.AddFilter(FBaseFilter, 'GRABBER');
  if FAILED(Result) then
    Exit;
  //Получаем интерфейс фильтра перехвата
  Result := FBaseFilter.QueryInterface(IID_ISampleGrabber, FSampleGrabber);
  if FAILED(Result) then
    Exit;

  if FSampleGrabber <> nil then
  begin
    //Устанавливаем формат данных для фильтра перехвата
    ZeroMemory(@MediaType, SizeOf(AM_MEDIA_TYPE));
    with MediaType do
    begin
      majortype := MEDIATYPE_Video;
      subtype := MEDIASUBTYPE_RGB24;
      formattype := FORMAT_VideoInfo;
    end;
    FSampleGrabber.SetMediaType(MediaType);
    // Данные будут записаны в буфер в том виде, в котором они проходят через фильтр
    FSampleGrabber.SetBufferSamples(True);
    // Граф не будет остановлен для получения кадра
    FSampleGrabber.SetOneShot(False);
    //
    FSampleGrabber.SetCallback(Self, 0);
  end;

  //Задаем граф фильтров
  Result := FCaptureGraphBuilder.SetFiltergraph(FGraphBuilder);
  if FAILED(Result) then
    Exit;
  //Получаем устройство для захвата видео
  Moniker.BindToObject(nil, nil, IID_IBaseFilter, FVideoCaptureFilter);
  //Добавляем устройство в граф фильтров  //Получаем фильтр графа захвата
  FGraphBuilder.AddFilter(FVideoCaptureFilter, 'VideoCaptureFilter');
  //Задаем, что откуда будем получать и куда оно должно выводиться
  Result := FCaptureGraphBuilder.RenderStream(@PIN_CATEGORY_PREVIEW, nil, FVideoCaptureFilter, FBaseFilter, nil);
  if FAILED(Result) then
    Exit;
  //Получаем интерфейс управления окном видео
  Result := FGraphBuilder.QueryInterface(IID_IVideoWindow, FVideoWindow);
  if FAILED(Result) then
    Exit;
  //ShowMessage(wd.ToString);
  //Задаем стиль окна вывода
  FVideoWindow.put_WindowStyle(WS_CHILD or WS_CLIPSIBLINGS);
  //Накладываем окно вывода
  FVideoWindow.put_Owner(Handle);
  //Задаем размеры окна во всю панель
  //FVideoRect := OutControl.ClientRect;
  FVideoWindow.SetWindowPosition(-1, -1, 0, 0);
  //Показываем окно
  FVideoWindow.put_Visible(False);
  //Запрашиваем интерфейс управления графом
  Result := FGraphBuilder.QueryInterface(IID_IMediaControl, FMediaControl);
  if FAILED(Result) then
    Exit;
  //Запускаем отображение с вебкамер
  FMediaControl.Run();
end;

procedure TFormMain.DrawPanel1Paint(Sender: TObject);
var
  FRect: TRect;
begin
  if DoPhoto then
  begin
    DrawPanel1.Canvas.Brush.Color := clWhite;
    DrawPanel1.Canvas.FillRect(DrawPanel1.ClientRect);
    Exit;
  end;
  if not Bitmap.Empty then
  begin
    FRect := DrawPanel1.ClientRect;

    FRect.Width := Round(FRect.Height * (Bitmap.Width / Bitmap.Height));
    if FRect.Width < DrawPanel1.ClientRect.Width then
    begin
      FRect.Width := DrawPanel1.ClientRect.Width;
      FRect.Height := Round(FRect.Width * (Bitmap.Height / Bitmap.Width));
    end;

    FRect.Offset(DrawPanel1.ClientRect.Width div 2 - FRect.Width div 2, DrawPanel1.ClientRect.Height div 2 - FRect.Height div 2);
    DrawPanel1.Canvas.StretchDraw(FRect, Bitmap);
  end;
end;

function TFormMain.CreatePhoto: TJPEGImage;
var
  bSize: integer;
  pVideoHeader: TVideoInfoHeader;
  MediaType: TAMMediaType;
  Bitmap: TBitmap;
  BitmapInfo: TBitmapInfo;
  Buffer: Pointer;
  buf: array of Byte;
  Check: HRESULT;
begin
  Result := TJpegImage.Create;
  //Если отсутствует интерфейс фильтра перехвата изображения, то завершаем работу
  if FSampleGrabber = nil then
    Exit;
  //Получаем размер буфера
  Check := FSampleGrabber.GetCurrentBuffer(bSize, nil);
  if (bSize <= 0) or FAILED(Check) then
    Exit;
  try
    //Получаем тип медиа потока на входе у фильтра перехвата
    ZeroMemory(@MediaType, SizeOf(TAMMediaType));
    Check := FSampleGrabber.GetConnectedMediaType(MediaType);
    if FAILED(Check) then
      Exit;

    //Копируем заголовок изображения
    pVideoHeader := TVideoInfoHeader(MediaType.pbFormat^);
    ZeroMemory(@BitmapInfo, SizeOf(TBitmapInfo));
    CopyMemory(@BitmapInfo.bmiHeader, @pVideoHeader.bmiHeader, SizeOf(TBITMAPINFOHEADER));

    //Создаем побитовое изображение
    Buffer := nil;
    Bitmap := TBitmap.Create;
    try
      Bitmap.Handle := CreateDIBSection(0, BitmapInfo, DIB_RGB_COLORS, Buffer, 0, 0);
      //Читаем изображение из медиа потока во временный буфер
      SetLength(buf, bSize);
      FSampleGrabber.GetCurrentBuffer(bSize, @buf[0]);
      //Копируем данные из временного буфера в наше изображение
      CopyMemory(Buffer, @buf[0], MediaType.lSampleSize);
      //Конвертируем изображение в Jpeg
      Result.Assign(Bitmap);
      Result.CompressionQuality := 30;
      Result.Compress;
    finally
      Bitmap.Free;
    end;
  finally
    SetLength(buf, 0);
  end;
end;

function TFormMain.BufferCB(SampleTime: Double; pBuffer: PByte; BufferLen: Integer): HResult;
begin
  Result := S_OK;
end;

procedure TFormMain.ButtonFlatPorpsClick(Sender: TObject);
var
  StreamConfig: IAMStreamConfig;
  PropertyPages: ISpecifyPropertyPages;
  Pages: CAUUID;
begin
  if FVideoCaptureFilter = nil then
    Exit;
  FMediaControl.Stop;
  try
    //Ищем интерфейс управления форматом данных выходного потока
    if SUCCEEDED(FCaptureGraphBuilder.FindInterface(@PIN_CATEGORY_CAPTURE, @MEDIATYPE_Video, FVideoCaptureFilter, IID_IAMStreamConfig, StreamConfig)) then
    begin
      //Пытаемся найти интерфейс управления страницами свойств
      if SUCCEEDED(StreamConfig.QueryInterface(ISpecifyPropertyPages, PropertyPages)) then
      begin
        //Получаем массив страниц свойств
        PropertyPages.GetPages(Pages);
        PropertyPages := nil;
        // Отображаем страницу свойств в виде модального диалога
        OleCreatePropertyFrame(Handle, 0, 0, PWideChar(ListBoxCams.Items.Strings[ListBoxCams.ItemIndex]), 1, @StreamConfig, Pages.cElems, Pages.pElems, 0, 0, NIL);
        //Готово
        StreamConfig := nil;
        CoTaskMemFree(Pages.pElems);
      end;
    end;
  finally
    FMediaControl.Run;
  end;
end;

procedure TFormMain.ButtonFlatTurnClick(Sender: TObject);
var
  B: Integer;
begin
  B := ClientWidth;
  ClientWidth := ClientHeight;
  ClientHeight := B;
end;

procedure TFormMain.ButtonFlatChangeCamClick(Sender: TObject);
begin
  if ListBoxCams.Count <= 0 then
    Exit;
  if ListBoxCams.ItemIndex + 1 > (ListBoxCams.Count - 1) then
    ListBoxCams.ItemIndex := 0
  else
    ListBoxCams.ItemIndex := ListBoxCams.ItemIndex + 1;
  if FAILED(CreateGraph(Monikers[ListBoxCams.ItemIndex])) then
  begin
    ShowMessage('Внимание! Произошла ошибка при построении графа фильтров');
    Exit;
  end;
end;

procedure TFormMain.ButtonFlatFlashClick(Sender: TObject);
begin
  if ButtonFlatFlash.ImageIndex = 2 then
    ButtonFlatFlash.ImageIndex := 3
  else
    ButtonFlatFlash.ImageIndex := 2;
  FDoFlash := ButtonFlatFlash.ImageIndex = 3;
end;

function TFormMain.SelectSavePath(var Path: string): Boolean;
begin
  Result := AdvSelectDirectory('Выберите каталог для сохранения снимков', '', Path, True);
end;

function TFormMain.GetPhotoFileName(const Path: string): string;
var
  N: Integer;
begin
  N := 0;
  repeat
    Inc(N);
    Result := Format('%s\Photo%s_%d.jpg', [Path, FormatDateTime('DDMMYYYY_HHMMSS', Now), N]);
  until not FileExists(Result);
end;

procedure TFormMain.ImageLastPhotoClick(Sender: TObject);
begin
  if FileExists(FLastFileName) then
  begin
    ShellExecute(Handle, 'open', PChar(FLastFileName), nil, nil, SW_NORMAL);
  end;
end;

procedure TFormMain.ButtonFlatPhotoClick(Sender: TObject);
var
  TS: Cardinal;
begin
  if FDoFlash then
  begin
    DoPhoto := True;
    DrawPanel1.Repaint;
    TS := GetTickCount + 1500;
    while TS > GetTickCount do
      Application.ProcessMessages;
  end
  else
  begin
    DoPhoto := True;
    DrawPanel1.Repaint;
    DoPhoto := False;
  end;
  with CreatePhoto do
  begin
    DoPhoto := False;
    ImageLastPhoto.Picture.Assign(Bitmap);
    if not ((not DirectoryExists(FSavePath)) and (not SelectSavePath(FSavePath))) then
    begin
      FLastFileName := GetPhotoFileName(FSavePath);
      SaveToFile(FLastFileName);
    end;
    Free;
  end;
end;

procedure TFormMain.FormCreate(Sender: TObject);
begin
  FAppClosing := False;
  FDoFlash := ButtonFlatFlash.ImageIndex = 3;
  Bitmap := TBitmap.Create;
  Monikers := TList<IMoniker>.Create;
  LoadSettings;
  CoInitialize(nil);
  //Инициализация списка камер
  if FAILED(CamsInit) then
  begin
    ShowMessage('Внимание! Произошла ошибка при инициализации');
    Exit;
  end;

  if ListBoxCams.Count > 0 then
  begin
    //Вызываем процедуру построения графа фильтров
    if FAILED(CreateGraph(Monikers[0])) then
    begin
      ShowMessage('Внимание! Произошла ошибка при построении графа фильтров');
      Exit;
    end;
  end
  else
    ShowMessage('Внимание! Камера не обнаружена.');
end;

procedure TFormMain.FormDestroy(Sender: TObject);
begin
  if FVideoCaptureFilter <> nil then
    FMediaControl.Stop;
  FAppClosing := True;
  Monikers.Clear;
  Monikers.Free;
  CoUninitialize;
  SaveSettings;
  IniFile.Free;
  Bitmap.Free;
end;

procedure TFormMain.ListBox1DblClick(Sender: TObject);
begin
  if (ListBoxCams.Count = 0) or (ListBoxCams.ItemIndex < 0) then
  begin
    ShowMessage('Камера не выбрана');
    Exit;
  end;

  if FAILED(CreateGraph(Monikers[ListBoxCams.ItemIndex])) then
  begin
    ShowMessage('Внимание! Произошла ошибка при построении графа фильтров');
    Exit;
  end;
end;

function TFormMain.SampleCB(SampleTime: Double; pSample: IMediaSample): HResult;
var
  BitmapInfo: TBitmapInfo;
  MediaType: TAMMediaType;
  pVideoHeader: TVideoInfoHeader;
  pBuffer: PByte;
  Buffer: Pointer;
begin
  Result := S_OK;
  if FAppClosing then
    Exit;
  if (pSample.GetSize = 0) then
    Exit;
  if not Assigned(FSampleGrabber) then
    Exit;
  Result := FSampleGrabber.GetConnectedMediaType(MediaType);
  if Failed(Result) then
    Exit;
  if IsEqualGUID(MediaType.majortype, MEDIATYPE_Video) then
  begin
    pSample.GetPointer(pBuffer);
    pVideoHeader := TVideoInfoHeader(MediaType.pbFormat^);
    CopyMemory(@BitmapInfo.bmiHeader, @pVideoHeader.bmiHeader, SizeOf(TBITMAPINFOHEADER));
    Buffer := nil;
    Bitmap.Handle := CreateDIBSection(0, BitmapInfo, DIB_RGB_COLORS, Buffer, 0, 0);
    try
      CopyMemory(Buffer, @pBuffer[0], MediaType.lSampleSize);
    except
      Result := E_FAIL;
    end;
    //DeleteObject(HBMP);
    DrawPanel1.Repaint;
  end;
end;

procedure TFormMain.LoadSettings;
begin
  IniFile := TIniFile.Create(ExtractFilePath(Application.ExeName) + 'config.ini');
  Left := IniFile.ReadInteger('General', 'Window.Left', 285);
  Top := IniFile.ReadInteger('General', 'Window.Top', 168);
  FSavePath := IniFile.ReadString('General', 'SavePath', '');
end;

procedure TFormMain.SaveSettings;
begin
  IniFile.WriteInteger('General', 'Window.Left', Left);
  IniFile.WriteInteger('General', 'Window.Top', Top);
  IniFile.WriteString('General', 'SavePath', FSavePath);
end;

end.

