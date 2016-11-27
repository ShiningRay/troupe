
export enum MessageType {
    invocation,
    result,
    error,
    event,
    system
}

export interface Message {
    id?: number;
    type: MessageType;
    from: any;
    to: any;
    extension?: any;
    timestamp?: number;
}

export interface InvocationMessage extends Message {
    type: MessageType.invocation;
    reqid: number;
    method: string;
    params: any[];
}

export interface ResultMessage extends Message {
    type: MessageType.result;
    reqid: number;
    result: any;
}

export interface EventMessage extends Message {
    type: MessageType.event;
    name: string;
    data: any;
}


export class ActorAddress {
    constructor(public threater: string,public stage: string,public actor: string){

    }
}

export interface ErrorMessage extends Message {
    type: MessageType.error;
    reqid: number;
    name: string;
    message: string;
    stack: string;
}


