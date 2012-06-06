{ TorChat - TTorChatClient, this component is implememting the client

  Copyright (C) 2012 Bernd Kreuss <prof7bit@gmail.com>

  This source is free software; you can redistribute it and/or modify it under
  the terms of the GNU General Public License as published by the Free
  Software Foundation; either version 3 of the License, or (at your option)
  any later version.

  This code is distributed in the hope that it will be useful, but WITHOUT ANY
  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
  FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
  details.

  A copy of the GNU General Public License is available on the World Wide Web
  at <http://www.gnu.org/copyleft/gpl.html>. You can also obtain it by writing
  to the Free Software Foundation, Inc., 59 Temple Place - Suite 330, Boston,
  MA 02111-1307, USA.
}
unit tc_client;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  SysUtils,
  tc_interface,
  tc_msgqueue,
  lnet,
  lEvents,
  tc_tor;

type
  { TEventThread is the thread that is polling the sockets
    and firing all the lNet callback methods }
  TEventThread = class(TThread)
    FEventer: TLEventer;
    FOutput: Text;
    constructor Create(AEventer: TLEventer);
    procedure Execute; override;
  end;

  { TTorChatClient implements the abstract IClient.
    Together with all its contained objects this represents
    a fully functional TorChat client. The GUI (or
    libpurpletorchat or a command line client) will
    derive a class from TTorChatClient overriding the
    virtual event methods (the methods that start with On
    (see the definition of IClient) to hook into the
    events and then create an instance of it.
    The GUI also must call TorChatClient.Pump() in regular
    intervals (1 second or so) from within the GUI-thread.
    Aditionally whenever there is an incoming chat message,
    status change or other event then TorChatClient will
    fire the OnNotifyGui event and as a response the
    GUI should schedule an additional call to Pump()
    from the GUI thread immediately. All other event method
    calls will then always originate from the thread that
    is calling Pump(), this method will process one queued
    event per call, it will never block and if there are
    no events and nothing else to do it will just return.}
  TTorChatClient = class(TComponent, IClient)
  strict private
    FMainThread: TThreadID;
    FEventThread: TEventThread;
    FProfileName: String;
    FClientConfig: IClientConfig;
    FRoster: IRoster;
    FTempList: ITempList;
    FIsDestroying: Boolean;
    FListenPort: DWord;
    FTorHost: String;
    FTorPort: DWord;
    FTor: TTor;
    FQueue: IMsgQueue;
    FTimeStarted: TDateTime;
    FHSNameOK: Boolean;
    FStatus: TTorchatStatus;
    FConnInList: IInterfaceList;
    FLnetEventer: TLEventer;
    FLnetListener: TLTcp;
    procedure OnListenerAccept(ASocket: TLSocket);
    procedure CheckHiddenServiceName;
    procedure CheckAnonConnTimeouts;
  public
    constructor Create(AOwner: TComponent; AProfileName: String); reintroduce;
    destructor Destroy; override;
    procedure Pump;
    procedure OnNeedPump; virtual; abstract;
    procedure OnGotOwnID; virtual; abstract;
    procedure OnBuddyStatusChange(ABuddy: IBuddy); virtual; abstract;
    procedure OnBuddyAdded(ABuddy: IBuddy); virtual; abstract;
    procedure OnBuddyRemoved(ABuddy: IBuddy); virtual; abstract;
    procedure OnInstantMessage(ABuddy: IBuddy; AText: String); virtual abstract;
    function MainThread: TThreadID;
    function Roster: IRoster;
    function TempList: ITempList;
    function Queue: IMsgQueue;
    function Config: IClientConfig;
    function IsDestroying: Boolean;
    function ProfileName: String;
    function TorHost: String;
    function TorPort: DWord;
    function HSNameOK: Boolean;
    function Status: TTorchatStatus;
    function LNetEventer: TLEventer;
    procedure SetStatus(AStatus: TTorchatStatus);
    procedure RegisterAnonConnection(AConn: IHiddenConnection);
    procedure UnregisterAnonConnection(AConn: IHiddenConnection);
  end;


implementation
uses
  tc_templist,
  tc_roster,
  tc_config,
  tc_misc,
  tc_conn,
  tc_const;

{ TEventThread }

constructor TEventThread.Create(AEventer: TLEventer);
begin
  FOutput := Output;
  FEventer := AEventer;
  FEventer.Timeout := 1000;
  inherited Create(False);
end;

procedure TEventThread.Execute;
begin
  Output := FOutput;
  repeat
    FEventer.CallAction;
  until Terminated;
  WriteLn('Network thread terminated');
end;

{ TTorChatClient }

constructor TTorChatClient.Create(AOwner: TComponent; AProfileName: String);
begin
  FIsDestroying := False;
  Inherited Create(AOwner);
  FLnetEventer := TLSelectEventer.Create; // deliberately avoid BestEventer until I have found the bug.
  FStatus := TORCHAT_OFFLINE;
  FMainThread := ThreadID;
  FProfileName := AProfileName;
  FClientConfig := TClientConfig.Create(AProfileName);
  Randomize;
  FHSNameOK := False;
  FTimeStarted := 0; // we will initialize it on first Pump() call
  FConnInList := TInterfaceList.Create;
  FQueue := TMsgQueue.Create(Self);
  FTempList := TTempList.Create(Self);
  FRoster := TRoster.Create(Self);
  FRoster.Load;

  FListenPort := Config.ListenPort;
  while not IsPortAvailable(FListenPort) do
    Dec(FListenPort);
  WriteLn(_F('I profile "%s": TorChat will open port %d for incoming connections',
    [AProfileName, FListenPort]));
  AddPortToList(FListenPort);

  FLnetListener := TLTcp.Create(self);
  with FLnetListener do begin
    Eventer := FLnetEventer;
    OnAccept := @OnListenerAccept;
    FLnetListener.Listen(FListenPort);
  end;

  FTor := TTor.Create(Self, Self, FListenPort);
  FTorHost := FTor.TorHost;
  FTorPort := FTor.TorPort;

  FEventThread := TEventThread.Create(FLnetEventer);
end;

destructor TTorChatClient.Destroy;
var
  Conn: IHiddenConnection;
begin
  WriteLn('start destroying TorChatClient');
  FIsDestroying := True;
  FEventThread.Terminate;

  // disconnect all buddies
  Roster.DoDisconnectAll;
  TempList.DoDisconnectAll;

  // disconnect all remaining incoming connections
  while FConnInList.Count > 0 do begin
    Conn := IHiddenConnection(FConnInList.Items[0]);
    Conn.Disconnect;
  end;

  FEventThread.Free;

  FRoster.Clear;
  FTempList.Clear;
  FQueue.Clear;

  FLnetListener.Free;
  RemovePortFromList(FListenPort);

  FLnetEventer.Free;

  WriteLn('start destroying child components');
  inherited Destroy;
  WriteLn('start destroying unreferenced interfaces');
end;

procedure TTorChatClient.Pump;
begin
  if FIsDestroying then exit;
  if FTimeStarted = 0 then FTimeStarted := Now;
  CheckHiddenServiceName;
  Queue.PumpNext;
  Roster.CheckState;
  TempList.CheckState;
  CheckAnonConnTimeouts;
end;

function TTorChatClient.MainThread: TThreadID;
begin
  Result := FMainThread;
end;

function TTorChatClient.Roster: IRoster;
begin
  Result := FRoster;
end;

function TTorChatClient.TempList: ITempList;
begin
  Result := FTempList;
end;

function TTorChatClient.Queue: IMsgQueue;
begin
  Result := FQueue;
end;

function TTorChatClient.Config: IClientConfig;
begin
  Result := FClientConfig;
end;

function TTorChatClient.IsDestroying: Boolean;
begin
  Result := FIsDestroying;
end;

function TTorChatClient.ProfileName: String;
begin
  Result := FProfileName;
end;

function TTorChatClient.TorHost: String;
begin
  Result := FTorHost;
end;

function TTorChatClient.TorPort: DWord;
begin
  Result := FTorPort;
end;

function TTorChatClient.HSNameOK: Boolean;
begin
  Result := FHSNameOK;
end;

function TTorChatClient.Status: TTorchatStatus;
begin
  Result := FStatus;
end;

function TTorChatClient.LNetEventer: TLEventer;
begin
  Result := FLnetEventer;
end;

procedure TTorChatClient.SetStatus(AStatus: TTorchatStatus);
var
  Buddy: IBuddy;
begin
  writeln('TTorChatClient.SetStatus(', AStatus, ')');
  FStatus := AStatus;
  for Buddy in Roster do
    if Buddy.IsFullyConnected then
      Buddy.SendStatus;
end;

procedure TTorChatClient.RegisterAnonConnection(AConn: IHiddenConnection);
begin
  FConnInList.Add(AConn);
  WriteLn(_F(
    'TTorChatClient.RegisterConnection() have now %d anonymous connections',
    [FConnInList.Count]));
end;

procedure TTorChatClient.UnregisterAnonConnection(AConn: IHiddenConnection);
begin
  // only incoming connections are in this list
  if FConnInList.IndexOf(AConn) <> -1 then begin
    FConnInList.Remove(AConn);
    WriteLn(_F(
      'TTorChatClient.UnregisterConnection() removed %s, %d anonymous connections left',
      [AConn.DebugInfo, FConnInList.Count]));
  end;
end;

procedure TTorChatClient.OnListenerAccept(ASocket: TLSocket);
var
  C : THiddenConnection;
begin
  writeln('TTorChatClient.OnListenerAccept()');
  if FIsDestroying then
    ASocket.Disconnect()
  else begin
    C := THiddenConnection.Create(Self, ASocket, nil);
    RegisterAnonConnection(C);
  end;
end;

procedure TTorChatClient.CheckHiddenServiceName;
var
  HSName: String;
begin
  if not FHSNameOK then begin;
    if TimeSince(FTimeStarted) < SECONDS_WAIT_FOR_HOSTNAME_FILE then begin
      HSName := FTor.HiddenServiceName;
      if HSName <> '' then begin
        writeln(_F('I profile "%s": HiddenService name is %s',
          [ProfileName, HSName]));
        Roster.SetOwnID(HSName);
        FHSNameOK := True;
        OnGotOwnID;
      end
      else
        writeln('TTorChatClient.CheckHiddenServiceName() not found');
    end;
  end;
end;

procedure TTorChatClient.CheckAnonConnTimeouts;
var
  Buddy: IBuddy;
  Conn: IHiddenConnection;
  I: Integer;
begin
  for I := FConnInList.Count - 1 downto 0 do begin
    Conn := IHiddenConnection(FConnInList.Items[I]);
    if TimeSince(Conn.TimeCreated) > SECONDS_WAIT_FOR_PONG then begin
      if Conn.PingBuddyID <> '' then begin
        Buddy := Roster.ByID(Conn.PingBuddyID);
        if not Assigned(Buddy) then
          Buddy := TempList.ByID(Conn.PingBuddyID);
        if Assigned(Buddy) then
          Buddy.ForgetLastPing;
        WriteLn(_F('I anonymous connection (allegedly %s) timed out, closing',
          [Conn.PingBuddyID]));
      end
      else
        WriteLn('I anonymous connection timed out, closing');
      Conn.Disconnect;
    end;
  end;
end;

end.

