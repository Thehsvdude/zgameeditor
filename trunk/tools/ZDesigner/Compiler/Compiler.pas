{Copyright (c) 2008 Ville Krumlinde

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.}

//This unit is the glue between ZExpressions and Zc
//VM code generation
unit Compiler;

interface

uses ZClasses,ZExpressions,Classes,uSymTab,SysUtils,Contnrs,ZApplication;

type
  EZcErrorBase = class(Exception)
  public
    Component : TZComponent;
    constructor Create(const M : string); reintroduce;
  end;

  ECodeGenError = class(EZcErrorBase);
  EParseError = class(EZcErrorBase)
  public
    Line,Col : integer;
  end;


procedure Compile(ZApp : TZApplication; ThisC : TZComponent;
  const Ze : TZExpressionPropValue;
  SymTab : TSymbolTable;
  ReturnType : TZcDataType;
  GlobalNames : TObjectList;
  AllowFuncDefs : boolean);

function ParsePropRef(SymTab : TSymbolTable;
  ThisC : TZComponent;
  const VarName: string;
  var Ref : TZPropertyRef) : boolean;


var
  CompileDebugString : string;

implementation

uses Zc,Zc_Ops, Vcl.Dialogs, Generics.Collections;


//ThisC = object som �r 'this'
function ParsePropRef(SymTab : TSymbolTable;
  ThisC : TZComponent;
  const VarName: string;
  var Ref : TZPropertyRef) : boolean;
var
  I : integer;
  CName,PName,IName : string;
  C : TZComponent;
  Prop : TZProperty;
begin
  Result := False;

  //bryt upp i objektnamn och propnamn, split '.'

  I := Pos('.',VarName);
  if I=0 then
  begin
    CName := '';
    PName := VarName;
  end
  else
  begin
    CName := Copy(VarName,1,I-1);
    PName := Copy(VarName,I+1,200);
  end;

  //Ta ev Propindex
  I := Pos('.',PName);
  if I=0 then
  begin
    Ref.Index := 0;
    Ref.HasPropIndex := False;
  end
  else
  begin
    IName := Copy(PName,I+1,200);
    PName := Copy(PName,1,I-1);
    if Length(IName)<>1 then
      Exit;
    //todo: testa typ av prop och s�tt verifiera propindex
    //"color.x" t.ex. ska ej g�
    case Upcase(IName[1]) of
      'X','R' : I := 0;
      'Y','G' : I := 1;
      'Z','B' : I := 2;
      'W','A' : I := 3;
    else
      Exit;
    end;
    Ref.Index := I;
    Ref.HasPropIndex := True;
  end;

  C := nil;
  if (CName='this') then
    C := ThisC
  else if (Length(CName)=0) then
  begin
    if SymTab.Contains(PName) then
    begin
      C := TZComponent(SymTab.Lookup(PName));
      if (C is TDefineVariable) or (C is TDefineConstant) then
      begin
        PName := 'Value';
        case (C as TDefineVariableBase)._Type of
          dvbInt : PName := 'IntValue';
          dvbString : PName := 'StringValue';
        end;
      end else
        C := nil;
    end
    else
      C := ThisC;
  end
  else
  begin
    if SymTab.Contains(CName) then
      C := TZComponent(SymTab.Lookup(CName));
  end;

  if Assigned(C) then
  begin
    Prop := C.GetProperties.GetByName(PName);
    if Assigned(Prop) then
    begin
      Ref.Component := C;
      Ref.Prop := Prop;
      Result := True;
    end;
  end;
end;


type
  TLabelUse = class
  private
    AdrPtr : PInteger;
    AdrPC : integer;
  end;

  TZCodeLabel = class
  private
    Usage : TObjectList;
    Definition : integer;
    constructor Create;
    destructor Destroy; override;
    function IsDefined : boolean;
  end;

  TAssignLeaveValueStyle = (alvNone,alvPre,alvPost);

  TZCodeGen = class
  private
    Target : TZComponentList;
    Component : TZComponent;
    ZApp : TZApplication;
    SymTab : TSymbolTable;
    Labels : TObjectList;
    LReturn : TZCodeLabel;
    CurrentFunction : TZcOpFunctionUserDefined;
    IsLibrary,IsExternalLibrary : boolean;
    BreakLabel,ContinueLabel : TZCodeLabel;
    BreakStack,ContinueStack : TStack<TZCodeLabel>;
    procedure Gen(Op : TZcOp);
    procedure GenJump(Kind : TExpOpJumpKind; Lbl : TZCodeLabel; T : TZcDataTypeKind = zctFloat);
    function NewLabel : TZCodeLabel;
    procedure DefineLabel(Lbl : TZCodeLabel);
    procedure ResolveLabels;
    procedure FallTrue(Op : TZcOp; Lbl : TZCodeLabel);
    procedure FallFalse(Op : TZcOp; Lbl : TZCodeLabel);
    procedure GenValue(Op : TZcOp);
    procedure GenFuncCall(Op : TZcOp; NeedReturnValue : boolean);
    procedure GenAssign(Op: TZcOp; LeaveValue : TAssignLeaveValueStyle);
    procedure GenAddress(Op : TZcOp);
    procedure GenAddToPointer(const Value : integer);
    procedure MakeLiteralOp(const Value: double; Typ: TZcDataType);
    procedure MakeStringLiteralOp(const Value : string);
    procedure SetBreak(L : TZCodeLabel);
    procedure SetContinue(L : TZCodeLabel);
    procedure RestoreBreak;
    procedure RestoreContinue;
  public
    procedure GenRoot(StmtList : TList);
    constructor Create;
    destructor Destroy; override;
  end;

function MakeBinaryOp(Kind : TExpOpBinaryKind; Typ : TZcDataType) : TExpBase;
begin
  case Typ.Kind of
    zctFloat :
      begin
        if Kind in [vbkBinaryOr,vbkBinaryAnd,vbkBinaryXor,vbkBinaryShiftLeft,vbkBinaryShiftRight,vbkMod] then
          raise ECodeGenError.Create('Cannot use this operator on a float-expression');
        Result := TExpOpBinaryFloat.Create(nil,Kind);
      end;
    zctInt : Result := TExpOpBinaryInt.Create(nil,Kind);
    zctString :
      begin
        if Kind<>vbkPlus then
          raise ECodeGenError.Create('Cannot use this operator on a string-expression');
        Result := TExpStringConCat.Create(nil);
      end;
  else
    raise ECodeGenError.Create('Wrong datatype for binaryop');
  end;
end;

function MakeAssignOp(Size : integer) : TExpBase;
begin
  case Size of
    4 : Result := TExpAssign4.Create(nil);
    1 : Result := TExpAssign1.Create(nil);
    100 : Result := TExpAssignPointer.Create(nil);
  else
    raise ECodeGenError.Create('Wrong datatype for assign');
  end;
end;


procedure TZCodeGen.MakeLiteralOp(const Value : double; Typ : TZcDataType);
begin
  case Typ.Kind of
    zctFloat :
      with TExpConstantFloat.Create(Target) do
        Constant := Value;
    zctInt :
      //Need to cast from double, otherwise precision problem: assert( StrToInt('$01111111'=17895697) );
      with TExpConstantInt.Create(Target) do
        Constant := Round(Value);
    zctNull :
      TExpConstantInt.Create(Target);
    else
      raise ECodeGenError.Create('Invalid literal: ' + FloatToStr(Value));
  end;
end;

procedure TZCodeGen.MakeStringLiteralOp(const Value : string);
var
  Con : TExpStringConstant;
  Op : TZcop;
begin
  Con := ZApp.AddToConstantPool(Value) as TExpStringConstant;
  Op := MakeOp(zcIdentifier);
  Op.Ref := Con;
  Op := MakeOp(zcSelect,[Op]);
  Op.Id := 'Value';
  GenValue(Op);
end;

//Genererar en op som skapar ett v�rde p� stacken
procedure TZCodeGen.GenValue(Op : TZcOp);

  procedure DoGenBinary(Kind : TExpOpBinaryKind);
  begin
    //Assert(Op.Arguments.Count=2);
    GenValue(Op.Child(0));
    GenValue(Op.Child(1));
    Target.AddComponent( MakeBinaryOp(Kind,Op.GetDataType) );
  end;

  procedure DoDeref(Op : TZcOp);
  var
    Etyp : TZcIdentifierInfo;
    PTyp : TZPropertyType;
    E : TExpMisc;
  begin
    Etyp := Op.GetIdentifierInfo;
    if ETyp.Kind=edtPropIndex then
      Etyp := Op.Children.First.GetIdentifierInfo;

    if Etyp.Kind=edtProperty then
      PTyp := Etyp.Prop.PropertyType
    else if Etyp.Kind=edtModelDefined then
      PTyp := zptComponentRef
    else
      raise ECodeGenError.Create('Failed to deref ' + Op.Id);

    E := TExpMisc.Create(Target);
    case PTyp of
      zptString,zptComponentRef: E.Kind := emPtrDerefPointer;
      zptByte,zptBoolean: E.Kind := emPtrDeref1;
    else
      E.Kind := emPtrDeref4;
    end;
  end;

  procedure DoGenIdentifier;
  var
    L : TExpAccessLocal;
    E : TExpMisc;
  begin
    if (Op.Ref is TZcOpLocalVar) or (Op.Ref is TZcOpArgumentVar) then
    begin
      //Local variable or argument
      L := TExpAccessLocal.Create(Target);
      L.Index := (Op.Ref as TZcOpVariableBase).Ordinal;
      L.Kind := loLoad;
      if (Op.Ref is TZcOpArgumentVar) and (Op.Ref as TZcOpArgumentVar).Typ.IsPointer then
      begin //"ref" argument, need to dereference pointer to get value
        E := TExpMisc.Create(Target);
        //todo: need attention in 64-bit mode
        E.Kind := emPtrDeref4;
      end;
    end else if LowerCase(Op.Id)='currentmodel' then
    begin
      with TExpMisc.Create(Target) do
        Kind := emLoadCurrentModel;
    end else if Op.Ref is TZComponent then
    begin
      with TExpLoadComponent.Create(Target) do
        Component := Op.Ref as TZComponent;
    end else
    begin
      //Property reference
      GenAddress(Op);
      DoDeref(Op);
    end;
  end;

  procedure DoGenSelect;
  var
    ETyp : TZcIdentifierInfo;
  begin
    ETyp := Op.GetIdentifierInfo;
    case ETyp.Kind of
      edtModelDefined :
        begin
          GenValue(Op.Children.First);
          with TExpLoadModelDefined.Create(Target) do
          begin
            DefinedIndex := ETyp.DefinedIndex;
            DefinedName := ETyp.Component.Name;
          end;
        end
      else
      begin
        GenAddress(Op);
        DoDeref(Op);
      end;
    end;
  end;

  procedure DoGenBoolean;
  //boolexpr "x<5" generates: if(boolexpr) push(1) else push(0)
  var
    LExit,LFalse : TZCodeLabel;
  begin
    LExit := NewLabel;
    LFalse := NewLabel;
    FallTrue(Op,LFalse);

    //Gen "true" body
    MakeLiteralOp(1, Op.GetDataType);
    //jump to exit
    GenJump(jsJumpAlways,LExit);

    //Gen "false"
    DefineLabel(LFalse);
    MakeLiteralOp(0, Op.GetDataType);

    DefineLabel(LExit);
  end;

  procedure DoGenArrayRead;
  var
    A : TZComponent;
    I : integer;
  begin
    A := TZComponent(SymTab.Lookup(Op.Id));
    if (A=nil) or (not (A is TDefineArray)) then
      raise ECodeGenError.Create('Identifier is not an array: ' + Op.Id);
    if Ord((A as TDefineArray).Dimensions)+1<>Op.Children.Count then
      raise ECodeGenError.Create('Wrong nr of array indices: ' + Op.ToString);
    for I := 0 to Op.Children.Count-1 do
      GenValue(Op.Child(I));//Indices
    GenValue((Op as TZcOpArrayAccess).ArrayOp);
    TExpArrayRead.Create(Target);
  end;

  procedure DoGenConvert;
  var
    C : TExpConvert;
    COp : TZcOpConvert;
    Kind : TExpConvertKind;
    FromOp : TZcOp;
    IdInfo : TZcIdentifierInfo;
    IsValue : boolean;
  begin
    COp := Op As TZcOpConvert;
    Kind := TExpConvertKind(99);
    FromOp := Cop.Child(0);
    IsValue := True;
    case FromOp.GetDataType.Kind of
      zctFloat :
        case Cop.ToType.Kind of
          zctInt: Kind := eckFloatToInt;
        end;
      zctInt :
        case Cop.ToType.Kind of
          zctFloat: Kind := eckIntToFloat;
        end;
      zctVoid :
        begin
          if (Cop.ToType.Kind=zctXptr) then
          begin
            IdInfo := FromOp.GetIdentifierInfo;
            if (IdInfo.Kind=edtProperty) and (idInfo.Prop.PropertyType=zptBinary) then
            begin
              Kind := eckBinaryToXptr;
              IsValue := False;
            end;
          end;
        end;
      zctReference :
        case Cop.ToType.Kind of
          zctXptr :
            begin
              if Assigned(FromOp.Ref) and (FromOp.Ref is TDefineArray) then
                Kind := eckArrayToXptr;
            end;
        end;
    end;
    if Ord(Kind)=99 then
      raise ECodeGenError.Create('Invalid conversion: ' + Op.ToString);
    if IsValue then
      GenValue(Op.Child(0))
    else
      GenAddress(Op.Child(0));
    C := TExpConvert.Create(Target);
    C.Kind := Kind;
  end;

  procedure DoLiteral;
  begin
    if Op.GetDataType.Kind=zctString then
      MakeStringLiteralOp((Op as TZcOpLiteral).StringValue)
    else
      MakeLiteralOp((Op as TZcOpLiteral).Value, Op.GetDataType);
  end;

  procedure DoGenConditional;
  //expr ? value1 : value2;
  var
    LExit,LFalse : TZCodeLabel;
  begin
    LFalse := NewLabel;
    LExit := NewLabel;

    FallTrue(Op.Child(0),LFalse);

    GenValue(Op.Child(1));
    GenJump(jsJumpAlways,LExit);

    DefineLabel(LFalse);
    GenValue(Op.Child(2));
    DefineLabel(LExit);
  end;

begin
  case Op.Kind of
    zcMul : DoGenBinary(vbkMul);
    zcDiv : DoGenBinary(vbkDiv);
    zcPlus : DoGenBinary(vbkPlus);
    zcMinus : DoGenBinary(vbkMinus);
    zcBinaryOr : DoGenBinary(vbkBinaryOr);
    zcBinaryAnd : DoGenBinary(vbkBinaryAnd);
    zcBinaryXor : DoGenBinary(vbkBinaryXor);
    zcBinaryShiftL : DoGenBinary(vbkBinaryShiftLeft);
    zcBinaryShiftR : DoGenBinary(vbkBinaryShiftRight);
    zcConstLiteral : DoLiteral;
    zcIdentifier : DoGenIdentifier;
    zcFuncCall : GenFuncCall(Op,True);
    zcCompLT,zcCompGT,zcCompEQ,
    zcCompNE,zcCompLE,zcCompGE,
    zcAnd, zcOr : DoGenBoolean;
    zcArrayAccess : DoGenArrayRead;
    zcConvert : DoGenConvert;
    zcAssign,zcPreInc,zcPreDec : GenAssign(Op,alvPost);
    zcPostInc,zcPostDec : GenAssign(Op,alvPre);
    zcConditional : DoGenConditional;
    zcSelect : DoGenSelect;
    zcReinterpretCast : GenValue(Op.Child(0));
    zcMod : DoGenBinary(vbkMod)
  else
    raise ECodeGenError.Create('Unsupported operator for value expression: ' + IntToStr(ord(Op.Kind)) );
  end;
end;

procedure TZCodeGen.GenAddToPointer(const Value: integer);
var
  Cnt : TExpConstantInt;
begin
  if Value=0 then
    Exit;

  if (Target.Last is TExpAddToPointer) then
  begin
    //Accumulate to previous add
    if (Target[ Target.Count-2 ] is TExpConstantInt) then
    begin
      Cnt := Target[ Target.Count-2 ] as TExpConstantInt;
      Inc(Cnt.Constant,Value);
      Exit;
    end;
  end;

  //Create new add
  Cnt := TExpConstantInt.Create(Target);
  Cnt.Constant := Value;
  TExpAddToPointer.Create(Target);
end;

procedure TZCodeGen.GenAddress(Op: TZcOp);

  procedure DoGenIdent;
  var
    L : TExpAccessLocal;
  begin
    if Assigned(Op.Ref) and (Op.Ref is TZcOpArgumentVar) and (Op.Ref as TZcOpArgumentVar).Typ.IsPointer then
    begin
      //The value of a ref-argument is the address to the referenced variable
      L := TExpAccessLocal.Create(Target);
      L.Index := (Op.Ref as TZcOpVariableBase).Ordinal;
      L.Kind := loLoad;
    end else if Assigned(Op.Ref) and (Op.Ref is TZcOpLocalVar) then
    begin //Get the address to a local variable
      L := TExpAccessLocal.Create(Target);
      L.Index := (Op.Ref as TZcOpVariableBase).Ordinal;
      L.Kind := loGetAddress;
    end
    else
      raise ECodeGenError.Create('Invalid address expression: ' + Op.Id);
  end;

  procedure DoGenSelect;
  var
    ETyp : TZcIdentifierInfo;
  begin
    ETyp := Op.GetIdentifierInfo;
    case ETyp.Kind of
      edtProperty :
        begin
          GenValue(Op.Children.First);
          with TExpLoadPropOffset.Create(Target) do
            PropId := ETyp.Prop.PropId;
          TExpAddToPointer.Create(Target);
        end;
      edtPropIndex :
        begin
          GenAddress(Op.Children.First);
          GenAddToPointer(ETyp.PropIndex * 4);
        end;
      else
        raise ECodeGenError.Create('Invalid datatype for select: ' + Op.Id);
    end;
  end;

begin
  case Op.Kind of
    zcIdentifier : DoGenIdent;
    zcSelect : DoGenSelect;
  else
    raise ECodeGenError.Create('Cannot get address of expression: ' + Op.ToString);
  end;
end;

procedure TZCodeGen.GenAssign(Op : TZcOp; LeaveValue : TAssignLeaveValueStyle);
//LeaveValue : Optionally leave a value of the assignment on stack.
//  alvPre: Leave the value prior to the assignment (i++)
//  alvPost: Leave the value after the assignment (++i)
var
  I,AssignSize : integer;

  A : TZComponent;
  LeftOp,RightOp : TZcOp;
  L : TExpAccessLocal;
  Etyp : TZcIdentifierInfo;
  Prop : TZProperty;
begin
  //Left-hand side of the assignment
  LeftOp := Op.Child(0);
  RightOp := Op.Child(1);

  if LeaveValue=alvPre then
    GenValue(LeftOp);

  if (LeftOp.Kind=zcIdentifier) and Assigned(LeftOp.Ref) and (LeftOp.Ref is TZcOpArgumentVar) and
    (LeftOp.Ref as TZcOpArgumentVar).Typ.IsPointer  then
  begin
    //Local "ref" argument
    GenAddress(LeftOp);
    GenValue(RightOp);
    Target.AddComponent( MakeAssignOp(4) ); //todo: need attention in 64-bit mode
    if LeaveValue=alvPost then
      GenValue(LeftOp);
  end else if (LeftOp.Kind=zcIdentifier) and Assigned(LeftOp.Ref) and
    ((LeftOp.Ref is TZcOpLocalVar) or (LeftOp.Ref is TZcOpArgumentVar))  then
  begin
    //Local variable or argument
    GenValue(RightOp);
    if LeaveValue=alvPost then
      with TExpMisc.Create(Target) do
        Kind := emDup;
    L := TExpAccessLocal.Create(Target);
    L.Index := (LeftOp.Ref as TZcOpVariableBase).Ordinal;
    L.Kind := loStore;
  end
  else if LeftOp.Kind=zcSelect then
  begin
    GenAddress(LeftOp);
    GenValue(RightOp);
    Etyp := LeftOp.GetIdentifierInfo;
    case Etyp.Kind of
      edtProperty : Prop := Etyp.Prop;
      edtPropIndex :
        begin
          Etyp := LeftOp.Children.First.GetIdentifierInfo;
          Assert(Etyp.Kind=edtProperty);
          Prop := Etyp.Prop;
        end
    else
      raise ECodeGenError.Create('Invalid type: ' + LeftOp.Id);
    end;
    if Prop.IsReadOnly then
      raise ECodeGenError.Create('Cannot assign readonly property identifier: ' + LeftOp.Id);
    if (Prop.PropertyType=zptString) and (not Prop.IsStringTarget) then
      raise ECodeGenError.Create('Cannot assign readonly property identifier: ' + LeftOp.Id);
    case Prop.PropertyType of
      zptString, zptComponentRef: AssignSize := 100;
      zptByte, zptBoolean: AssignSize := 1;
    else
      AssignSize := 4;
    end;
    Target.AddComponent( MakeAssignOp(AssignSize) );
    if LeaveValue=alvPost then
      GenValue(LeftOp);
  end else if LeftOp.Kind=zcArrayAccess then
  begin
    if LeaveValue=alvPost then
      raise ECodeGenError.Create('Assign syntax not supported for this kind of variable');
    A := TZComponent(SymTab.Lookup(LeftOp.Id));
    if (A=nil) or (not (A is TDefineArray)) then
      raise ECodeGenError.Create('Identifier is not an array: ' + LeftOp.Id);
    if Ord((A as TDefineArray).Dimensions)+1<>LeftOp.Children.Count then
      raise ECodeGenError.Create('Wrong nr of array indices: ' + Op.ToString);
    for I := 0 to LeftOp.Children.Count-1 do
      GenValue(LeftOp.Child(I)); //Indices
    GenValue((LeftOp as TZcOpArrayAccess).ArrayOp);
    TExpArrayWrite.Create(Target);
    GenValue(Op.Child(1));
    Target.AddComponent( MakeAssignOp((A as TDefineArray).GetElementSize) );
  end else
    raise ECodeGenError.Create('Assignment destination must be variable or array: ' + Op.Child(0).Id);

end;

procedure TZCodeGen.Gen(Op : TZcOp);
var
  I : integer;

  procedure DoGenIf;
  var
    LExit,LElse : TZCodeLabel;
    HasElse : boolean;
  begin
    HasElse := Assigned(Op.Child(2));
    LExit := NewLabel;
    if HasElse then
    begin
      LElse := NewLabel;
      FallTrue(Op.Child(0),LElse);
    end
    else
    begin
      LElse := nil;
      FallTrue(Op.Child(0),LExit);
    end;
    //Gen "then" body
    Gen(Op.Child(1));
    if HasElse then
    begin //ELSE
      //Write jump past else-body for then-body
      GenJump(jsJumpAlways,LExit);
      DefineLabel(LElse);
      //Gen else-body
      Gen(Op.Child(2));
    end;
    DefineLabel(LExit);
  end;

  procedure DoGenForLoop;
  var
    LExit,LLoop,LContinue : TZCodeLabel;
  begin
    //Children: [ForInitOp,ForCondOp,ForIncOp,ForBodyOp]
    if Assigned(Op.Child(0)) then
      Gen(Op.Child(0));

    LExit := NewLabel;
    LLoop := NewLabel;
    LContinue := NewLabel;
    DefineLabel(LLoop);

    SetBreak(LExit);
    SetContinue(LContinue);

    if Assigned(Op.Child(1)) then
      FallTrue(Op.Child(1),LExit);

    if Assigned(Op.Child(3)) then
      Gen(Op.Child(3));

    DefineLabel(LContinue);
    if Assigned(Op.Child(2)) then
      Gen(Op.Child(2));
    GenJump(jsJumpAlways,LLoop);

    DefineLabel(LExit);
    RestoreBreak;
    RestoreContinue;
  end;

  procedure DoWhile;
  var
    LExit,LLoop : TZCodeLabel;
  begin
    //Children: [WhileCondOp,WhileBodyOp]
    LExit := NewLabel;

    LLoop := NewLabel;
    DefineLabel(LLoop);

    SetBreak(LExit);
    SetContinue(LLoop);

    if Assigned(Op.Child(0)) then
      FallTrue(Op.Child(0),LExit);

    if Assigned(Op.Child(1)) then
      Gen(Op.Child(1));
    GenJump(jsJumpAlways,LLoop);

    DefineLabel(LExit);
    RestoreBreak;
    RestoreContinue;
  end;

  procedure DoGenReturn;
  var
    L : TExpAccessLocal;
  begin
    //"return x", generate value + jump to exit
    if not Assigned(LReturn) then
      //Global label shared for all return statements
      LReturn := NewLabel;
    if CurrentFunction.ReturnType.Kind<>zctVoid then
    begin
      GenValue(Op.Child(0));
      //Store return value in local0
      L := TExpAccessLocal.Create(Target);
      L.Index := 0;
      L.Kind := loStore;
    end;
    GenJump(jsJumpAlways,LReturn);
  end;

  procedure DoGenFunction(Func : TZcOpFunctionUserDefined);
  var
    I : integer;
    Frame : TExpStackFrame;
    Ret : TExpReturn;
  begin
    if (Func.Id='') and (Func.Statements.Count=0) then
      Exit; //Don't generate code for empty nameless function (such as Repeat.WhileExp)
    if IsLibrary then
    begin
      Func.Lib := Component as TZLibrary;
      Func.LibIndex := Target.Count;
    end;
    if IsExternalLibrary and (Func.Id<>'') then
    begin
      Func.IsExternal := True;
      if Func.Statements.Count>0 then
        raise ECodeGenError.Create('External functions definitions can not have a body: ' + Func.Id );
      Func.ExtLib := Component as TZExternalLibrary;
    end;
    Self.CurrentFunction := Func;
    if Func.NeedFrame then
    begin
      Frame := TExpStackFrame.Create(Target);
      Frame.Size := Func.GetStackSize;
    end;
    for I := 0 to Func.Statements.Count - 1 do
    begin
      Gen(Func.Statements[I] as TZcOp);
    end;
    if Assigned(LReturn) then
    begin
      DefineLabel(LReturn);
      LReturn := nil;
    end;
    Ret := TExpReturn.Create(Target);
    Ret.HasFrame := Func.NeedFrame;
    Ret.HasReturnValue := Func.ReturnType.Kind<>zctVoid;
    Ret.Arguments := Func.Arguments.Count;
  end;

  procedure DoGenSwitch(Op : TZcOpSwitch);
  var
    I,J,CaseCount : integer;
    CaseLabels : array of TZCodeLabel;
    CaseType : TZcDataType;
    LExit,LDefault : TZCodeLabel;
    CaseOp,StatOp : TZcOp;
  begin
    //todo: verify no duplicate values
    CaseCount := Op.CaseOps.Count;
    CaseType := Op.ValueOp.GetDataType;
    SetLength(CaseLabels,CaseCount);
    LExit := NewLabel;
    SetBreak(LExit);
    LDefault := nil;
    //Generate jumps
    for I := 0 to CaseCount-1 do
    begin
      CaseLabels[I] := NewLabel;
      CaseOp := Op.CaseOps[I];
      for J := 0 to CaseOp.Children.Count - 1 do
      begin
        if CaseOp.Child(J)=nil then
        begin
          LDefault := CaseLabels[I];
        end else
        begin
          GenValue(Op.ValueOp);
          GenValue(CaseOp.Child(J));
          GenJump(jsJumpEQ,CaseLabels[I],CaseType.Kind);
        end;
      end;
    end;
    if LDefault<>nil then
      GenJump(jsJumpAlways,LDefault,CaseType.Kind)
    else
      GenJump(jsJumpAlways,LExit,CaseType.Kind);
    //Generate statements
    for I := 0 to CaseCount-1 do
    begin
      DefineLabel(CaseLabels[I]);
      StatOp := Op.StatementsOps[I];
      for J := 0 to StatOp.Children.Count - 1 do
        Gen( StatOp.Child(J) );
    end;
    DefineLabel(LExit);
    RestoreBreak;
  end;

  procedure DoGenInvoke(Op : TZcOpInvokeComponent);
  var
    Inv : TExpInvokeComponent;
    Ci : TZComponentInfo;
    Arg : TZcOp;
    Prop : TZProperty;
  begin
    Ci := ComponentManager.GetInfoFromName(Op.Id);
    for Arg in Op.Children do
    begin
      Prop := Ci.GetProperties.GetByName(Arg.Id);
      Assert(Prop<>nil);
      GenValue(Arg.Children.First);
      with TExpConstantInt.Create(Target) do
        Constant := Prop.PropId;
    end;
    Inv := TExpInvokeComponent.Create(Target);
    Inv.InvokeClassId := integer( Ci.ClassId );
    Inv.InvokeArgCount := Op.Children.Count;
  end;

begin
  case Op.Kind of
    zcAssign,zcPreInc,zcPreDec,zcPostDec,zcPostInc : GenAssign(Op,alvNone);
    zcIf : DoGenIf;
    zcNop : ;
    zcBlock :
      for I := 0 to Op.Children.Count-1 do
        Gen(Op.Child(I));
    zcReturn : DoGenReturn;
    zcFuncCall : GenFuncCall(Op,False);
    zcFunction : DoGenFunction(Op as TZcOpFunctionUserDefined);
    zcForLoop : DoGenForLoop;
    zcWhile : DoWhile;
    zcBreak :
      if Assigned(Self.BreakLabel) then
        GenJump(jsJumpAlways,Self.BreakLabel)
      else
        raise ECodeGenError.Create('Break can only be used in loops');
    zcContinue :
      if Assigned(Self.ContinueLabel) then
        GenJump(jsJumpAlways,Self.ContinueLabel)
      else
        raise ECodeGenError.Create('Continue can only be used in loops');
    zcSwitch : DoGenSwitch(Op as TZcOpSwitch);
    zcInvokeComponent : DoGenInvoke(Op as TZcOpInvokeComponent);
  else
    raise ECodeGenError.Create('Unsupported operator: ' + IntToStr(ord(Op.Kind)) );
  end;
end;

destructor TZCodeGen.Destroy;
begin
  Labels.Free;
  BreakStack.Free;
  ContinueStack.Free;
  inherited;
end;

constructor TZCodeGen.Create;
begin
  Labels := TObjectList.Create;
  BreakStack := TStack<TZCodeLabel>.Create;
  ContinueStack := TStack<TZCodeLabel>.Create;
end;

procedure TZCodeGen.DefineLabel(Lbl: TZCodeLabel);
begin
  if Lbl.IsDefined then
    raise ECodeGenError.Create('Label already defined');
  Lbl.Definition := Target.Count;
end;

function TZCodeGen.NewLabel: TZCodeLabel;
begin
  Result := TZCodeLabel.Create;
  Labels.Add(Result);
end;

procedure TZCodeGen.GenJump(Kind: TExpOpJumpKind; Lbl: TZCodeLabel; T : TZcDataTypeKind = zctFloat);
var
  Op : TExpJump;
  U : TLabelUse;
begin
  Op := TExpJump.Create(Target);
  Op.Kind := Kind;
  case T of
    zctFloat: Op._Type := jutFloat;
    zctInt,zctModel,zctNull,zctReference: Op._Type := jutInt;
    zctString:
      begin
        Op._Type := jutString;
        if not (Kind in [jsJumpNE,jsJumpEQ,jsJumpAlways]) then
          raise ECodeGenError.Create('Invalid string comparison');
      end
  else
    raise ECodeGenError.Create('Invalid datatype for jump');
  end;
  U := TLabelUse.Create;
  U.AdrPtr := @Op.Destination;
  U.AdrPC := Target.Count-1;
  Lbl.Usage.Add( U );
end;

procedure TZCodeGen.GenRoot(StmtList: TList);
var
  I : integer;
begin
  IsLibrary := Component is TZLibrary;
  IsExternalLibrary := Component is TZExternalLibrary;
  for I := 0 to StmtList.Count-1 do
    Gen(StmtList[I]);
  ResolveLabels;
end;

procedure TZCodeGen.ResolveLabels;
var
  I,J,Adr : integer;
  Lbl : TZCodeLabel;
  U : TLabelUse;
begin
  for I := 0 to Labels.Count-1 do
  begin
    Lbl := TZCodeLabel(Labels[I]);
    if Lbl.Definition=-1 then
      raise ECodeGenError.Create('Label with missing definition');
    for J := 0 to Lbl.Usage.Count-1 do
    begin
      U := TLabelUse(Lbl.Usage[J]);
      Adr := Lbl.Definition - U.AdrPC - 1;
      U.AdrPtr^ := Adr;
    end;
  end;
end;

procedure TZCodeGen.RestoreBreak;
begin
  BreakLabel := BreakStack.Pop;
end;

procedure TZCodeGen.RestoreContinue;
begin
  ContinueLabel := ContinueStack.Pop;
end;

procedure TZCodeGen.SetBreak(L: TZCodeLabel);
begin
  BreakStack.Push(Self.BreakLabel);
  Self.BreakLabel := L;
end;

procedure TZCodeGen.SetContinue(L: TZCodeLabel);
begin
  ContinueStack.Push(Self.ContinueLabel);
  Self.ContinueLabel := L;
end;

//Fall igenom om false, annars hoppa till Lbl
procedure TZCodeGen.FallFalse(Op: TZcOp; Lbl: TZCodeLabel);

  procedure DoGenComp(Kind : TExpOpJumpKind);
  begin
    //Assert(Op.Arguments.Count=2);
    GenValue(Op.Child(0));
    GenValue(Op.Child(1));
    GenJump(Kind,Lbl,Op.Child(0).GetDataType.Kind);
  end;

  procedure DoGenAnd;
  var
    LAnd : TZCodeLabel;
  begin
    LAnd := NewLabel;
    FallTrue(Op.Child(0),LAnd);
    FallFalse(Op.Child(1),Lbl);
    DefineLabel(LAnd);
  end;

  procedure DoGenOr;
  begin
    FallFalse(Op.Child(0),Lbl);
    FallFalse(Op.Child(1),Lbl);
  end;

  procedure DoGenValue;
  begin
    //if(1) blir: value,0, compare and jump
    GenValue(Op);
    MakeLiteralOp(0, Op.GetDataType);
    GenJump(jsJumpNE,Lbl, Op.GetDataType.Kind);
  end;

begin
  case Op.Kind of
    zcCompLT : DoGenComp(jsJumpLT);
    zcCompGT : DoGenComp(jsJumpGT);
    zcCompEQ : DoGenComp(jsJumpEQ);
    zcCompNE : DoGenComp(jsJumpNE);
    zcCompLE : DoGenComp(jsJumpLE);
    zcCompGE : DoGenComp(jsJumpGE);
    zcAnd : DoGenAnd;
    zcOr : DoGenOr;
    zcNot : FallTrue(Op.Child(0),Lbl);
  else
    //zcConst,zcIdentifier,zcFuncCall etc
    DoGenValue;
  end;
end;

//Fall igenom om true, annars hoppa till Lbl
procedure TZCodeGen.FallTrue(Op: TZcOp; Lbl: TZCodeLabel);

  procedure DoGenComp(Kind : TExpOpJumpKind);
  begin
    //Assert(Op.Arguments.Count=2);
    GenValue(Op.Child(0));
    GenValue(Op.Child(1));
    GenJump(Kind,Lbl,Op.Child(0).GetDataType.Kind);
  end;

  procedure DoGenAnd;
  begin
    FallTrue(Op.Child(0),Lbl);
    FallTrue(Op.Child(1),Lbl);
  end;

  procedure DoGenOr;
  var
    LOr : TZCodeLabel;
  begin
    LOr := NewLabel;
    FallFalse(Op.Child(0),LOr);
    FallTrue(Op.Child(1),Lbl);
    DefineLabel(LOr);
  end;

  procedure DoGenValue;
  begin
    //if(1) blir: value,0, compare and jump
    GenValue(Op);
    MakeLiteralOp(0, Op.GetDataType);
    GenJump(jsJumpEQ,Lbl,Op.GetDataType.Kind);
  end;

begin
  case Op.Kind of
    //Generera varje j�mf�relses motsats
    zcCompLT : DoGenComp(jsJumpGE);
    zcCompGT : DoGenComp(jsJumpLE);
    zcCompEQ : DoGenComp(jsJumpNE);
    zcCompNE : DoGenComp(jsJumpEQ);
    zcCompLE : DoGenComp(jsJumpGT);
    zcCompGE : DoGenComp(jsJumpLT);
    zcAnd : DoGenAnd;
    zcOr : DoGenOr;
    zcNot : FallFalse(Op.Child(0),Lbl);
  else
    //zcConst,zcIdentifier,zcFuncCall etc
    DoGenValue;
  end;
end;

procedure TZCodeGen.GenFuncCall(Op: TZcOp; NeedReturnValue : boolean);

  procedure DoGenBuiltInFunc(Func : TZcOpFunctionBuiltIn);
  var
    I : integer;
    F : TExpFuncCall;
    SF : TExpPointerFuncCall;
  begin
    if NeedReturnValue and (Func.ReturnType.Kind=zctVoid) then
      raise ECodeGenError.Create('Function in expression must return a value: ' + Op.Id);
    if Op.Children.Count<>Func.Arguments.Count then
      raise ECodeGenError.Create('Invalid nr of arguments: ' + Op.Id);
    for I := 0 to Func.Arguments.Count-1 do
      if Func.Arguments[I].Typ.IsPointer then
        GenAddress(Op.Child(I))
      else
        GenValue(Op.Child(I));
    if Func.FuncId in [fcIntToStr,fcSubStr,fcChr,fcCreateModel] then
    begin
      SF := TExpPointerFuncCall.Create(Target);
      SF.Kind := Func.FuncId;
    end else
    begin
      F := TExpFuncCall.Create(Target);
      F.Kind := Func.FuncId;
    end;
    if (not NeedReturnValue) and (Func.ReturnType.Kind<>zctVoid) then
      //discard return value from stack
      with TExpMisc.Create(Target) do
        Kind := emPop;
  end;

  procedure DoGenUserFunc(UserFunc : TZcOpFunctionUserDefined);
  var
    I : integer;
    F : TExpUserFuncCall;
    FE : TExpExternalFuncCall;
    {$ifdef CPUX64}
    S : AnsiString;
    Arg : TZcOpArgumentVar;
    {$endif}
  begin
    if NeedReturnValue and (UserFunc.ReturnType.Kind=zctVoid) then
      raise ECodeGenError.Create('Function in expression must return a value: ' + Op.Id);
    if Op.Children.Count<>UserFunc.Arguments.Count then
      raise ECodeGenError.Create('Invalid nr of arguments: ' + Op.Id);

    for I := 0 to UserFunc.Arguments.Count-1 do
    begin
      if UserFunc.Arguments[I].Typ.IsPointer then
        GenAddress(Op.Child(I))
      else
        GenValue(Op.Child(I));
    end;

    if UserFunc.IsExternal then
    begin
      FE := TExpExternalFuncCall.Create(Target);
      FE.Lib := UserFunc.ExtLib;
      FE.SetString('FuncName',AnsiString(UserFunc.Id));
      FE.ArgCount := UserFunc.Arguments.Count;
      FE.ReturnType := UserFunc.ReturnType;
      {$ifdef CPUX64}
      S := '';
      for Arg in UserFunc.Arguments do
      begin
        if Arg.Typ.IsPointer then
          S := S + AnsiChar( zctXptr )
        else
          S := S + AnsiChar( Arg.Typ.Kind );
      end;
      FE.SetString('ArgTypes',S);
      {$endif}
    end
    else
    begin
      F := TExpUserFuncCall.Create(Target);
      F.Lib := UserFunc.Lib;
      F.Index := UserFunc.LibIndex;
    end;

    if (not NeedReturnValue) and (UserFunc.ReturnType.Kind<>zctVoid) then
      //discard return value from stack
      with TExpMisc.Create(Target) do
        Kind := emPop;
  end;

begin
  Assert(Op.Kind=zcFuncCall);
  if SymTab.Contains(Op.Id) and (SymTab.Lookup(Op.Id) is TZcOpFunctionUserDefined) then
  begin
    DoGenUserFunc(SymTab.Lookup(Op.Id) as TZcOpFunctionUserDefined);
  end else if SymTab.Contains(Op.Id) and (SymTab.Lookup(Op.Id) is TZcOpFunctionBuiltIn) then
  begin
    DoGenBuiltInFunc(SymTab.Lookup(Op.Id) as TZcOpFunctionBuiltIn);
  end else raise ECodeGenError.Create('Unknown function: ' + Op.Id);
end;

{ TZCodeLabel }

constructor TZCodeLabel.Create;
begin
  Usage := TObjectList.Create;
  Self.Definition := -1;
end;

destructor TZCodeLabel.Destroy;
begin
  Usage.Free;
  inherited;
end;

function TZCodeLabel.IsDefined: boolean;
begin
  Result := Definition<>-1;
end;

//////////////////////////



procedure Compile(ZApp: TZApplication; ThisC : TZComponent; const Ze : TZExpressionPropValue;
  SymTab : TSymbolTable; ReturnType : TZcDataType;
  GlobalNames : TObjectList;
  AllowFuncDefs : boolean);
var
  Compiler : TZc;
  CodeGen : TZCodeGen;
  I : integer;
  S : string;
  Target : TZComponentList;
begin
  S := Ze.Source;
  Target := Ze.Code;

  CompilerContext.SymTab := SymTab;
  CompilerContext.ThisC := ThisC;

  Compiler := TZc.Create(nil);
  try
    Compiler.SymTab := SymTab;
    Compiler.ReturnType := ReturnType;
    Compiler.GlobalNames := GlobalNames;

    Compiler.SetSource(S);

    Compiler.AllowFunctions := AllowFuncDefs;
    Compiler.Execute;

    if Compiler.Successful then
    begin
      for I:=0 to Compiler.ZFunctions.Count-1 do
        Compiler.ZFunctions[I] := TZcOp(Compiler.ZFunctions[I]).Optimize;
    end else
      raise EParseError.Create('Compilation failed');

    Target.Clear;
    CodeGen := TZCodeGen.Create;
    try
      CodeGen.Target := Target;
      CodeGen.Component := ThisC;
      CodeGen.SymTab := SymTab;
      CodeGen.ZApp := ZApp;
      try
        CodeGen.GenRoot(Compiler.ZFunctions);
      except
        //Om n�got g�r fel under kodgenereringen s� rensa koden s� att den inte k�rs
        Target.Clear;
        raise;
      end;

      //Show tree as source-code for debugging
      CompileDebugString := '';
      for I := 0 to Compiler.ZFunctions.Count-1 do
        CompileDebugString := CompileDebugString + (Compiler.ZFunctions[I] as TZcOp).ToString + #13#10;

    finally
      CodeGen.Free;
    end;
  finally
    Compiler.Free;
  end;

end;

{ EZcErrorBase }

constructor EZcErrorBase.Create(const M: string);
begin
  Self.Message := M;
  Self.Component := CompilerContext.ThisC;
end;

end.

