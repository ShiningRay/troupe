import {Ref} from './core';

export interface RemoteCallMessage {
    from: Ref;
    to: Ref;
    reqid: number;
    method: string;
    args: any[];
}

export interface RemoteResultMessage {
    from: Ref;
    to: Ref;
    reqid: number;
    result: any;
}

export interface ErrorResultMessage {
    from: Ref;
    to: Ref;
    reqid: number;
    error: any;
}
