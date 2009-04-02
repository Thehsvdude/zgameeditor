unit frmBitmapEdit;

interface

uses
  Windows, Messages, SysUtils, Variants, Classes, Graphics, Controls, Forms,
  Dialogs, frmCompEditBase, ExtCtrls, ZClasses,DesignerGui, Contnrs, ZBitmap,
  Menus, StdCtrls;

type
  TBitmapEditFrame = class(TCompEditFrameBase)
    Image: TImage;
    PopupMenu1: TPopupMenu;
    AddMenuItem: TMenuItem;
    DeleteMenuItem: TMenuItem;
    Panel1: TPanel;
    PaintBox: TPaintBox;
    procedure ImageMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure ImageMouseMove(Sender: TObject; Shift: TShiftState; X,
      Y: Integer);
    procedure ImageMouseUp(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure PaintBoxPaint(Sender: TObject);
    procedure DeleteMenuItemClick(Sender: TObject);
    procedure FrameResize(Sender: TObject);
    procedure PopupMenu1Popup(Sender: TObject);
  private
    { Private declarations }
    Nodes : TObjectList;
    Bitmap : TZBitmap;
    IsBitmapConnected : boolean;
    SelectedNode : TObject;
    DragMode : (drmNone,drmMove,drmLink);
    DragPos,DragDst : TPoint;
    DragLinkIndex : integer;
    procedure RepaintPage;
    procedure ReadFromComponent;
    procedure WriteToComponent;
    function FindNodeAt(X,Y : integer) : TObject;
    procedure InitPopupMenu;
    procedure OnAddClick(Sender: TObject);
    procedure Layout;
  public
    { Public declarations }
    constructor Create(AOwner: TComponent) ; override;
    destructor Destroy; override;
    procedure SetComponent(C : TZComponent; TreeNode : TZComponentTreeNode); override;
    procedure OnPropChanged; override;
    procedure OnTreeChanged; override;
  end;

var
  BitmapEditFrame: TBitmapEditFrame;

implementation

uses Meshes, Math, SugiyamaLayout, ZLog, frmEditor;

{$R *.dfm}

const
  NodeWidth = 85;
  NodeHeight = 36;

type
  TBitmapNode = class
  private
    Links : TObjectList;
    ParamCount : integer;
    Page : TBitmap;
    Pos : TPoint;
    Producer : TZComponent;
    Form : TBitmapEditFrame;
    TempId : integer;
    constructor Create(Form : TBitmapEditFrame; Producer : TZComponent; Page : TBitmap; X, Y, ParamCount: integer);
    destructor Destroy; override;
    procedure DrawLinks;
    procedure Draw;
    procedure AddLink(Node : TBitmapNode);
    procedure ChangeLink(Node : TBitmapNode; Index : integer);
    function GetTreeSize : integer;
    function GetParamPos(I: integer): TPoint;
    function GetParamRect(I: integer): TRect;
    function GetOutputRect: TRect;
  end;

  TMyLayout = class(TSugiyamaLayout)
  private
    BitmapNodes : TObjectList;
  public
    constructor Create(BitmapNodes : TObjectList);
    procedure ExtractNodes; override;
    procedure ApplyNodes; override;
  end;

{ TBitmapNode }

procedure TBitmapNode.AddLink(Node: TBitmapNode);
begin
  if Links.Count>=ParamCount then
    raise Exception.Create('No more links allowed');
  Links.Add(Node);
end;

procedure TBitmapNode.ChangeLink(Node: TBitmapNode; Index: integer);
begin
  if Links.IndexOf(Node)>-1 then
    Exit;

  if (Node=nil) and (Index<Links.Count) then
    Links.Delete(Index);

  if Node<>nil then
    Links.Add(Node);
end;

constructor TBitmapNode.Create(Form : TBitmapEditFrame; Producer : TZComponent; Page : TBitmap; X, Y, ParamCount: integer);
begin
  Self.Page := Page;
  Self.Producer := Producer;
  Self.ParamCount := ParamCount;
  Pos.X := X;
  Pos.Y := Y;
  Links := TObjectList.Create(False);
  Self.Form := Form;
end;

const
  ParamRadius = 5;
  ParamStep = ParamRadius * 2 + 4;
  OutputRadius = 4;
  OutputStep = OutputRadius * 2 + 4;

function TBitmapNode.GetOutputRect: TRect;
var
  P : TPoint;
begin
  P.X := Pos.X + NodeWidth div 2;;
  P.Y := Pos.Y + OutputStep div 2;
  Result.Left := P.X - OutputRadius;
  Result.Right := P.X + OutputRadius;
  Result.Top := P.Y - OutputRadius;
  Result.Bottom := P.Y + OutputRadius;
end;

function TBitmapNode.GetParamPos(I : integer) : TPoint;
var
  Left : integer;
begin
  Left := Pos.X + NodeWidth div 2 - ((ParamCount * ParamStep) div 2);
  Result.X := Left + I * ParamStep + ParamStep div 2;
  Result.Y := Pos.Y + NodeHeight - ParamStep div 2;
end;

function TBitmapNode.GetParamRect(I: integer): TRect;
var
  P : TPoint;
begin
  P := GetParamPos(I);
  Result.Left := P.X - ParamRadius;
  Result.Right := P.X + ParamRadius;
  Result.Top := P.Y - ParamRadius;
  Result.Bottom := P.Y + ParamRadius;
end;

destructor TBitmapNode.Destroy;
begin
  Links.Free;
end;

procedure TBitmapNode.Draw;
var
  Str : string;
  I : integer;
  C : TCanvas;
  Selected : boolean;
  R : TRect;
begin
  Selected := Form.SelectedNode = Self;

  Str := ComponentManager.GetInfo(Producer).ZClassName;
  Str := StringReplace(Str,'Bitmap','',[]);

  C := Page.Canvas;
  //Back
  if Selected then
    C.Brush.Color := RGB(190, 190, 220)
  else
    C.Brush.Color := RGB(190, 190, 190);

  C.Pen.Color := clGray;
  if Selected then
    C.Brush.Color := RGB(170, 170, 230)
  else
    C.Brush.Color := RGB(190, 190, 190); //RGB(170, 170, 170);
  C.Rectangle(Pos.X, Pos.Y, Pos.X + NodeWidth, Pos.Y + NodeHeight);

  //Text
  C.Brush.Style := bsClear;
  C.TextOut(Pos.X + (NodeWidth - C.TextWidth(Str)) div 2,
    Pos.Y + (NodeHeight - C.TextHeight(Str)) div 2,
    Str);
  C.Brush.Style := bsSolid;

  //Links
  for I := 0 to ParamCount-1 do
  begin
    if I<Links.Count then
      C.Brush.Color := clRed
    else
      C.Brush.Color := clLime;
    R := GetParamRect(I);
    C.Brush.Color := RGB(200, 200, 200);
    C.Ellipse(R.Left,R.Top,R.Right,R.Bottom);
  end;

  R := GetOutputRect;
  Inc(R.Left,OutputRadius);
//  C.Brush.Color := clDkGray;
  C.Brush.Color := RGB(200, 200, 200);
  C.Polygon([ Point(R.Left,R.Top),Point(R.Right,R.Bottom),Point(R.Left - OutputRadius,R.Bottom) ]);
end;

procedure TBitmapNode.DrawLinks;
var
  I : integer;
  C : TCanvas;
  Link : TBitmapNode;
  P : TPoint;
begin
  C := Page.Canvas;
  for I := 0 to Links.Count-1 do
  begin
    Link := TBitmapNode(Links[I]);
    C.Pen.Color := clBlack;
    P := GetParamPos(I);
    C.MoveTo(P.X,P.Y);
    C.LineTo(Link.Pos.X + NodeWidth div 2, Link.Pos.Y + NodeHeight div 2);
  end;
end;

function TBitmapNode.GetTreeSize: integer;

  function InCountChildren(Node : TBitmapNode) : integer;
  var
    I : integer;
  begin
    Result := Links.Count;
    for I := 0 to Node.Links.Count - 1 do
      Inc(Result, InCountChildren(TBitmapNode(Node.Links[I])) );
  end;

begin
  Result := 0;
  Inc(Result, InCountChildren(Self) );
end;

{ TMyLayout }

constructor TMyLayout.Create(BitmapNodes: TObjectList);
begin
  Self.BitmapNodes := BitmapNodes;
end;

procedure TMyLayout.ExtractNodes;
var
  I,J : integer;
  Node,FromNode,ToNode : TNode;
  BitmapNode,Other : TBitmapNode;
begin
  inherited;

  for I := 0 to BitmapNodes.Count-1 do
  begin
    BitmapNode := TBitmapNode(BitmapNodes[I]);
    Node := TNode.Create;
    Node.H := NodeHeight;
    Node.W := NodeWidth;
    Node.Control := BitmapNode;
    Node.Id := Nodes.Count;
    BitmapNode.TempId := Node.Id;
    Nodes.Add(Node);
  end;

  for I := 0 to BitmapNodes.Count-1 do
  begin
    BitmapNode := TBitmapNode(BitmapNodes[I]);
    for J := 0 to BitmapNode.Links.Count-1 do
    begin
      Other := TBitmapNode(BitmapNode.Links[J]);
      FromNode := Nodes[BitmapNode.TempId];
      ToNode := Nodes[Other.TempId];
      AddEdge(FromNode,ToNode);
    end;
  end;

end;

procedure TMyLayout.ApplyNodes;
var
  I : integer;
  Node : TNode;
  BitmapNode : TBitmapNode;
begin
  inherited;

  for I := 0 to Nodes.Count-1 do
  begin
    Node := Nodes[I];
    if Node.IsDummy then
      Continue;
    BitmapNode := Node.Control as TBitmapNode;
    BitmapNode.Pos.X := Node.X;
    BitmapNode.Pos.Y := Node.Y;
  end;
end;

{ TBitmapEditFrame }

constructor TBitmapEditFrame.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Nodes := TObjectList.Create(True);

  InitPopupMenu;

  Panel1.DoubleBuffered := True;
end;

procedure TBitmapEditFrame.InitPopupMenu;
var
  Infos : PComponentInfoArray;
  Ci : TZComponentInfo;
  I : TZClassIds;
  M : TMenuItem;
begin
  Infos := ZClasses.ComponentManager.GetAllInfos;
  for I := Low(TComponentInfoArray) to High(TComponentInfoArray) do
  begin
    Ci := TZComponentInfo(Infos[I]);
    if Ci.NoUserCreate then
      Continue;
    if not (Ci.ZClass.InheritsFrom(TContentProducer)) then
      Continue;
    if (Ci.ZClass.InheritsFrom(TMeshProducer)) then
      Continue; //TODO: test for inherits BitmapProducer instead

    M := TMenuItem.Create(AddMenuItem);
    M.Caption := Ci.ZClassName;
    M.OnClick := OnAddClick;
    M.Tag := Integer(Ci);
    AddMenuItem.Add(M);
  end;
end;

procedure TBitmapEditFrame.Layout;
var
  L : TMyLayout;
begin
  if not IsBitmapConnected then
    Exit;

  if Bitmap.Producers.Count=0 then
    Exit;

  L := TMyLayout.Create(Nodes);
  try
    L.Execute;
  finally
    L.Free;
  end;
end;


destructor TBitmapEditFrame.Destroy;
begin
  Nodes.Free;
  inherited;
end;

function TBitmapEditFrame.FindNodeAt(X, Y: integer): TObject;
var
  I : integer;
  Node : TBitmapNode;
  P : TPoint;
  R : TRect;
begin
  Result := nil;
  P.X := X;
  P.Y := Y;
  for I := 0 to Nodes.Count - 1 do
  begin
    Node := TBitmapNode(Nodes[I]);
    R.Left := Node.Pos.X;
    R.Top := Node.Pos.Y;
    R.Right := R.Left + NodeWidth;
    R.Bottom := R.Top + NodeHeight;
    if PtInRect(R,P) then
    begin
      Result := Node;
      Break;
    end;
  end;
end;

procedure TBitmapEditFrame.FrameResize(Sender: TObject);
begin
  RepaintPage;
end;

procedure TBitmapEditFrame.ImageMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  Node : TBitmapNode;
  I : integer;
  P : TPoint;
begin
  Node := TBitmapNode(FindNodeAt(X,Y));

  SelectedNode := Node;

  if Node<>nil then
  begin
    (Owner as TEditorForm).FindComponentAndFocusInTree(Node.Producer);

    DragLinkIndex := -1;
    P := Point(X,Y);
    for I := 0 to Node.ParamCount-1 do
      if PtInRect(Node.GetParamRect(I),P) then
      //Drag from parameter
      begin
        DragLinkIndex := I;
        DragMode := drmLink;
        Break;
      end;

    if (DragLinkIndex=-1) and PtInRect(Node.GetOutputRect,P) then
      //Drag from output
      DragMode := drmLink;

    DragPos := P;
    DragDst := P;

//    if DragLinkIndex >= 0 then
//    begin
{    end
    else
    begin
      DragMode := drmMove;
      DragPos := Point(X - Node.Pos.X,Y - Node.Pos.Y);
    end;}
  end;

  RepaintPage;
end;

procedure TBitmapEditFrame.ImageMouseMove(Sender: TObject; Shift: TShiftState;
  X, Y: Integer);
var
  DoPaint : boolean;
begin
  DoPaint := False;

  if (DragMode=drmMove) and Assigned(SelectedNode) then
  begin
//Disable move for now, only use autolayout
//    TBitmapNode(SelectedNode).Pos := Point((X - DragPos.X) div 10 * 10, (Y - DragPos.Y) div 10 * 10);
//    DoPaint := True;
  end;

  if DragMode=drmLink then
  begin
    DragDst := Point(X,Y);
    DoPaint := True;
  end;

  if DoPaint then
    RepaintPage;
end;

procedure TBitmapEditFrame.ImageMouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  Node,Other,FromNode,ToNode : TBitmapNode;
  I : integer;
  P : TPoint;

  procedure InBreakCycle(Fn,Tn : TBitmapNode);
  var
    I,J : integer;
  begin
    J := Tn.Links.IndexOf(Fn);
    if J>-1 then
      Tn.ChangeLink(nil,J)
    else for I := 0 to Tn.Links.Count - 1 do
      InBreakCycle(Fn,TBitmapNode(Tn.Links[I]));
  end;

begin
  if DragMode=drmLink then
  begin
    Other := TBitmapNode(FindNodeAt(X,Y));
    if Other<>nil then
    begin
      if DragLinkIndex=-1 then
      begin //Link from one nodes output to another nodes input argument
        FromNode := Other;
        ToNode := TBitmapNode(SelectedNode);
        P := Point(X,Y);
        for I := 0 to FromNode.ParamCount-1 do
          if PtInRect(FromNode.GetParamRect(I),P) then
          begin
            DragLinkIndex := I;
            Break;
          end;
      end else
      begin //Link from input to output
        FromNode := TBitmapNode(SelectedNode);
        ToNode := Other;
      end;

      if (FromNode<>ToNode) and (DragLinkIndex>-1) then
      begin
        FromNode.ChangeLink(ToNode,DragLinkIndex);
        //make sure that no other link has ToNode as target
        for I := 0 to Nodes.Count - 1 do
        begin
          Node := TBitmapNode(Nodes[I]);
          if Node=FromNode then
            Continue;
          if Node.Links.IndexOf(ToNode)>-1 then
            Node.Links.Remove(ToNode);
        end;
        //make sure that tonode does not link back to fromnode
        InBreakCycle(FromNode,ToNode);
        WriteToComponent;
        ReadFromComponent;
        PaintBox.Invalidate;
      end;
    end;
  end;

  DragMode := drmNone;
  RepaintPage;
end;

procedure TBitmapEditFrame.SetComponent(C: TZComponent; TreeNode: TZComponentTreeNode);
begin
  inherited;

  Self.Bitmap := C as TZBitmap;
  ReadFromComponent;

  RepaintPage;
  PaintBox.Invalidate;
end;

procedure TBitmapEditFrame.ReadFromComponent;
var
  I,ParamCount : integer;
  C : TZComponent;
  Stack : TObjectStack;
  Node : TBitmapNode;
begin
  IsBitmapConnected := False;

  Nodes.Clear;

{   hur l�nka ihop?
     l�s en p
       om p inte �r en producer fail "kan inte visa som graf"
     paramcount=p params
       l�s paramcount fr�n stack
       addera som children till p
     push p p� stack}

  Stack := TObjectStack.Create;
  try

    for I := 0 to Bitmap.Producers.Count - 1 do
    begin
      C := Bitmap.Producers.GetComponent(I);

      if not (C is TContentProducer) then
      begin
        ZLog.GetLog(Self.ClassName).Write('Diagram can only handle bitmap-producer components.');
        Exit;
      end;

      ParamCount := ComponentManager.GetInfo(C).ParamCount;
      Node := TBitmapNode.Create(Self,C,Image.Picture.Bitmap,I*100,10,ParamCount);
      Nodes.Add( Node );

      while (ParamCount>0) and (Stack.Count>0) do
      begin
        Node.AddLink( TBitmapNode(Stack.Pop) );
        Dec(ParamCount);
      end;

      Stack.Push(Node);
    end;

    IsBitmapConnected := True;
  finally
    Stack.Free;
  end;

  Layout;

  DragMode := drmNone;
end;


function TempIdSortProc(Item1, Item2: Pointer): Integer;
var
  I1,I2 : integer;
begin
  I1 := TBitmapNode(Item1).TempId;
  I2 := TBitmapNode(Item2).TempId;
  if I1 < I2 then
    Result := -1
  else if I1 = I2 then
    Result:=0
  else
    Result := 1;
end;


procedure TBitmapEditFrame.WriteToComponent;
var
  I,J : integer;
  Node : TBitmapNode;
  InCounts : array of integer;
  Roots,Producers : TObjectList;
  C : TZComponent;

  procedure InGenNode(Node : TBitmapNode);
  var
    I : integer;
  begin
    for I := 0 to Node.Links.Count - 1 do
      InGenNode(TBitmapNode(Node.Links[I]));
    Producers.Add(Node.Producer);
  end;

begin
{           clear b.producers
           hitta rot i tr�d (=den som inte �r child till n�gon annan)
             om flera r�tter generera dom i ordningen minst tr�d f�rst
           depth first children
             f�rst traversera barn
             sen generera sig sj�lv}
  if (not IsBitmapConnected) then
    Exit;

  SetLength(InCounts,Nodes.Count);
  FillChar(InCounts[0],SizeOf(Integer)*Nodes.Count,0);

  for I := 0 to Nodes.Count-1 do
  begin
    Node := TBitmapNode(Nodes[I]);
    Node.TempId := I;
  end;

  for I := 0 to Nodes.Count-1 do
  begin
    Node := TBitmapNode(Nodes[I]);
    for J := 0 to Node.Links.Count - 1 do
      Inc(InCounts[ TBitmapNode(Node.Links[J]).TempId ]);
  end;

  Roots := TObjectList.Create(False);
  Producers := TObjectList.Create(False);
  try
    for I := 0 to High(InCounts) do
      if InCounts[I]=0 then
      begin
        Node := TBitmapNode(Nodes[I]);
        Node.TempId := Node.GetTreeSize;
        Roots.Add( Node );
      end;

    Roots.Sort(TempIdSortProc);

    for I := 0 to Roots.Count-1 do
    begin
      Node := TBitmapNode(Roots[I]);
      InGenNode(Node);
    end;

    for I := 0 to Producers.Count-1 do
    begin
      C := Producers[I] as TZComponent;
      J := Bitmap.Producers.IndexOf(C);
      if J<>-1 then
        Bitmap.Producers.RemoveAt(J);
      Bitmap.Producers.InsertComponent(C,I)
    end;
    Bitmap.Producers.Change;

  finally
    Roots.Free;
    Producers.Free;
  end;

  RefreshTreeNode;
end;


procedure TBitmapEditFrame.RepaintPage;
var
  I : integer;
  C : TCanvas;
begin
  C := Image.Picture.Bitmap.Canvas;

  Image.Picture.Bitmap.SetSize(Image.ClientRect.Right,Image.ClientRect.Bottom);
  C.Brush.Color := clWhite;
  C.FillRect(Image.ClientRect);

  if not IsBitmapConnected then
  begin
    C.TextOut(10,10,'Diagram cannot be shown of bitmaps containing logical components');
  end
  else
  begin
    for I := 0 to Nodes.Count-1 do
      TBitmapNode(Nodes[I]).DrawLinks;

    for I := 0 to Nodes.Count-1 do
      TBitmapNode(Nodes[I]).Draw;

    if DragMode = drmLink then
    begin
      C.Pen.Color := clLime;
      C.MoveTo(DragPos.X, DragPos.Y);
      C.LineTo(DragDst.X, DragDst.Y);
    end;
  end;

end;

procedure TBitmapEditFrame.OnAddClick(Sender: TObject);
var
  M : TMenuItem;
  Ci : TZComponentInfo;
  C : TZComponent;
begin
  if not IsBitmapConnected then
    Exit;

  M := Sender as TMenuItem;
  Ci := TZComponentInfo(M.Tag);
  C := Ci.ZClass.Create(nil);

  Nodes.Add( TBitmapNode.Create(Self,C,Image.Picture.Bitmap,0,0,0) );

  WriteToComponent;
  ReadFromComponent;

  RepaintPage;
  PaintBox.Invalidate;
end;

procedure TBitmapEditFrame.DeleteMenuItemClick(Sender: TObject);
begin
  if (not IsBitmapConnected) or (not Assigned(SelectedNode)) then
    Exit;

  (Owner as TEditorForm).DeleteComponentActionExecute(Self);

  ReadFromComponent;
  SetProjectChanged;

  RepaintPage;
  PaintBox.Invalidate;
end;

procedure TBitmapEditFrame.OnPropChanged;
begin
  PaintBox.Invalidate;
end;

procedure TBitmapEditFrame.OnTreeChanged;
begin
  ReadFromComponent;
  RepaintPage;
  PaintBox.Invalidate;
end;

procedure TBitmapEditFrame.PaintBoxPaint(Sender: TObject);
var
  Data : pointer;
  Bmi : TBitmapInfo;
  W,H : integer;
  C : TCanvas;
begin
  C := PaintBox.Canvas;

  Data := Bitmap.GetCopyAsBytes;

  W := Bitmap.PixelWidth;
  H := Bitmap.PixelHeight;

  ZeroMemory(@Bmi, SizeOf(Bmi));
  with Bmi.bmiHeader do
  begin
    biSize     := SizeOf(bmi.bmiHeader);
    biWidth    := W;
    biHeight   := H;
    biPlanes   := 1;
    biBitCount := 24;
  end;

  SetStretchBltMode(C.Handle, HALFTONE);

  StretchDIBits(C.Handle, 0, 0,
    PaintBox.ClientRect.Right, PaintBox.ClientRect.Bottom,
    0, 0, W, H, Data, Bmi, DIB_RGB_COLORS, SRCCOPY);

  FreeMem(Data);
end;



procedure TBitmapEditFrame.PopupMenu1Popup(Sender: TObject);
begin
  DeleteMenuItem.Enabled := SelectedNode<>nil;
end;

end.