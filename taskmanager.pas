{
  Copyright (C) 2012 Mohsen Timar mohsen.timar@gmail.com

  This library is free software; you can redistribute it and/or modify it
  under the terms of the GNU Library General Public License as published by
  the Free Software Foundation; either version 2 of the License, or (at your
  option) any later version with the following modification:

  This program is distributed in the hope that it will be useful, but WITHOUT
  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE. See the GNU Library General Public License
  for more details.
}
unit TaskManager;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fgl, syncobjs;

type
  TTaskManager = class;

  TResource = class

  end;

  TResourceClass = class of TResource;

  TResourceList = specialize TFPGList<TResource>;
  TResourceClassList = specialize TFPGList<TResourceClass>;

  TTaskState = (tsReady, tsStarting, tsRunning, tsTerminated, tsKilled);

  { TTask }

  TTask = class
  private
    FOnFinish: TNotifyEvent;
    FOnKilled: TNotifyEvent;
    FOnStart: TNotifyEvent;

    FOwner: TTaskManager;
    FResources: TResourceList;
    FResourcesClass: TResourceClassList;

    FState: TTaskState;

    FRunner: TThread;

    procedure Execute;
  protected

    procedure RegisterResource(AResourceClass: TResourceClass);
    function GetResource(AResourceClass: TResourceClass): TResource;

    procedure RequestResources; virtual;
    procedure Run; virtual;

  public

    constructor Create(AOwner: TTaskManager); virtual;
    destructor Destroy; override;

    property OnFinish: TNotifyEvent read FOnFinish write FOnFinish;
    property OnStart: TNotifyEvent read FOnStart write FOnStart;
    property OnKilled: TNotifyEvent read FOnKilled write FOnKilled;

  end;

  TTaskList = specialize TFPGList<TTask>;

  { TTaskRunner }

  TTaskRunner = class(TThread)
  private
    FTask: TTask;
    procedure OnFinish();
    procedure OnStart();
  protected
    procedure Execute; override;
  public
    constructor Create(ATask: TTask);
  end;

  { TTaskManager }

  TTaskManager = class(TThread)
  private
    FAutoRun: boolean;
    FFreeResourcesOnTerminate: boolean;
    FOnFinish: TNotifyEvent;
    FOnPause: TNotifyEvent;
    FOnResume: TNotifyEvent;

    FTasks: TTaskList;
    FResources: TResourceList;

    FTaskLock: TCriticalSection;
    FWaitForTask: PRTLEvent;

    FPaused: boolean;

    FRunningTask: integer;
    FRunnerLimit: integer;

    function CheckResources(ATask: TTask): boolean;
    function GetResource(AResourceClass: TResourceClass): TResource;
    function GetTask(Index: integer): TTask;
    function GetTaskCount: integer;
    procedure ReleaseTaskResources(ATask: TTask);

    procedure DoFinish();

  protected

    procedure Execute; override;

  public

    constructor Create;
    destructor Destroy; override;

    procedure KillTask(ATask: TTask);
    procedure StartTask(ATask: TTask);

    procedure AddTask(ATask: TTask);
    procedure AddResource(AResource: TResource);

    procedure Pause;
    procedure Resume;

    property Tasks[Index: integer]: TTask read GetTask;
    property TaskCount: integer read GetTaskCount;

    property AutoRun: boolean read FAutoRun write FAutoRun;
    property FreeResourcesOnTerminate: boolean
      read FFreeResourcesOnTerminate write FFreeResourcesOnTerminate;

    property Paused: boolean read FPaused;

    property OnPause: TNotifyEvent read FOnPause write FOnPause;
    property OnResume: TNotifyEvent read FOnResume write FOnResume;
    property OnFinish: TNotifyEvent read FOnFinish write FOnFinish;
  end;

implementation

{ TTaskManager }

function TTaskManager.CheckResources(ATask: TTask): boolean;
var
  AResource: TResource;
  I: integer;
begin
  Result := False;
  for I := 0 to ATask.FResourcesClass.Count - 1 do
  begin
    AResource := GetResource(ATask.FResourcesClass[I]);
    if (AResource = nil) then
    begin
      ReleaseTaskResources(ATask);
      Exit;
    end;
    ATask.FResources.Add(AResource);
  end;
  Result := True;
end;

function TTaskManager.GetResource(AResourceClass: TResourceClass): TResource;
var
  I: integer;
begin
  for I := 0 to FResources.Count - 1 do
  begin
    Result := FResources[I];
    if (Result.ClassType = AResourceClass) then
    begin
      FResources.Remove(Result);
      Exit;
    end;
  end;
  Result := nil;
end;

function TTaskManager.GetTask(Index: integer): TTask;
begin
  Result := FTasks[Index];
end;

function TTaskManager.GetTaskCount: integer;
begin
  Result := FTasks.Count;
end;

procedure TTaskManager.ReleaseTaskResources(ATask: TTask);
var
  I: integer;
begin
  for I := 0 to ATask.FResources.Count - 1 do
  begin
    FResources.Add(ATask.FResources[I]);
  end;
  ATask.FResources.Clear;
end;

procedure TTaskManager.DoFinish;
begin
  Pause;
  if (Assigned(FOnFinish)) then
  begin
    FOnFinish(Self);
  end;
end;

procedure TTaskManager.Execute;
var
  ATask: TTask;
  Count, I: integer;
  AResource: TResource;
begin
  while not Terminated do
  begin

    if (FTasks.Count = 0) then
    begin
      Synchronize(@DoFinish);
      //RTLeventWaitFor(FWaitForTask, 1000);
    end;

    FTaskLock.Enter;
    Count := FTasks.Count;
    I := 0;

    while I < Count do
    begin

      ATask := FTasks[I];

      if (ATask.FState in [tsTerminated, tsKilled]) then
      begin
        FTasks.Remove(ATask);
        Dec(Count);
        ReleaseTaskResources(ATask);
        if (Assigned(ATask.FRunner)) then
        begin
          ATask.FRunner.Free;
          Dec(FRunningTask);
        end;
        ATask.Free;
      end;

      Inc(I);
    end;
    if (FTasks.Count > 0) and (FRunnerLimit > FRunningTask) then
    begin
      ATask := FTasks[0];
      if (ATask.FState = tsReady) then
      begin
        if (CheckResources(ATask)) then
        begin
          Inc(FRunningTask);
          StartTask(ATask);
        end;
      end;
    end;
    FTaskLock.Leave;
  end;

  FTaskLock.Enter;
  Count := FTasks.Count;

  while Count > 0 do
  begin

    ATask := FTasks[0];
    KillTask(ATask);
    FTasks.Remove(ATask);
    Dec(Count);
    ReleaseTaskResources(ATask);
    if (Assigned(ATask.FRunner)) then
    begin
      ATask.FRunner.Free;
      Dec(FRunningTask);
    end;
    ATask.Free;

  end;

  Count := FResources.Count;

  if (FFreeResourcesOnTerminate) then
  begin
    while Count > 0 do
    begin

      AResource := FResources[0];
      FResources.Remove(AResource);
      Dec(Count);
      AResource.Free;

    end;
  end;

  FTaskLock.Leave;
end;

constructor TTaskManager.Create;
begin
  inherited Create(True);
  FTasks := TTaskList.Create;
  FResources := TResourceList.Create;
  FTaskLock := TCriticalSection.Create;
  FWaitForTask := RTLEventCreate;
  FPaused := False;
  FRunnerLimit := 1;
  FRunningTask := 0;
  FFreeResourcesOnTerminate := True;
end;

destructor TTaskManager.Destroy;
var
  I: integer;
begin
  if (not Terminated) then
  begin
    Terminate;
    WaitFor;
  end;
  FResources.Free;
  FTasks.Free;
  RTLeventdestroy(FWaitForTask);
  FTaskLock.Free;
  inherited Destroy;
end;

procedure TTaskManager.KillTask(ATask: TTask);
begin
  if (Assigned(ATask.FRunner)) then
  begin
    KillThread(ATask.FRunner.Handle);
    //Dec(FRunningTask);
  end;
  ATask.FState := tsKilled;
  if (Assigned(ATask.FOnKilled)) then
  begin
    ATask.FOnKilled(ATask);
  end;
end;

procedure TTaskManager.StartTask(ATask: TTask);
var
  ARunner: TTaskRunner;
begin
  ATask.FState := tsStarting;
  ARunner := TTaskRunner.Create(ATask);
  ARunner.Start;
end;

procedure TTaskManager.AddTask(ATask: TTask);
begin
  FTasks.Add(ATask);
  ATask.RequestResources;
  ATask.FState := tsReady;
  RTLeventSetEvent(FWaitForTask);
end;

procedure TTaskManager.AddResource(AResource: TResource);
begin
  FResources.Add(AResource);
end;

procedure TTaskManager.Pause;
begin
  if (FPaused) then
    Exit;
  FTaskLock.Enter;
  FPaused := True;
  if (Assigned(FOnPause)) then
    FOnPause(Self);
end;

procedure TTaskManager.Resume;
begin
  if (not FPaused) then
    Exit;
  FPaused := False;
  if (Suspended) then
    Start;
  FTaskLock.Leave;
  if (Assigned(FOnResume)) then
    FOnResume(Self);
end;

{ TTaskRunner }

procedure TTaskRunner.OnFinish;
begin
  //Dec(FTask.FOwner.FRunningTask);
  if (Assigned(FTask.FOnFinish)) then
    FTask.FOnFinish(FTask);
  FTask.FState := tsTerminated;
end;

procedure TTaskRunner.OnStart;
begin
  //Inc(FTask.FOwner.FRunningTask);
  FTask.FState := tsRunning;
  if (Assigned(FTask.FOnStart)) then
    FTask.FOnStart(FTask);
end;

procedure TTaskRunner.Execute;
begin
  Synchronize(@OnStart);
  FTask.Execute;
  Synchronize(@OnFinish);
end;

constructor TTaskRunner.Create(ATask: TTask);
begin
  inherited Create(True);
  FTask := ATask;
  FTask.FRunner := Self;
end;

{ TTask }

procedure TTask.Execute;
begin
  Run;
end;

procedure TTask.RegisterResource(AResourceClass: TResourceClass);
begin
  FResourcesClass.Add(AResourceClass);
end;

function TTask.GetResource(AResourceClass: TResourceClass): TResource;
var
  I: integer;
begin
  for I := 0 to FResources.Count - 1 do
  begin
    if (FResources.Items[I].ClassType = AResourceClass) then
    begin
      Result := FResources.Items[I];
      Exit;
    end;
  end;
  Result := nil;
end;

procedure TTask.RequestResources;
begin

end;

constructor TTask.Create(AOwner: TTaskManager);
begin
  FOwner := AOwner;
  FResources := TResourceList.Create;
  FResourcesClass := TResourceClassList.Create;
end;

destructor TTask.Destroy;
begin
  FResources.Free;
  FResourcesClass.Free;
  inherited Destroy;
end;

procedure TTask.Run;
begin

end;

end.
