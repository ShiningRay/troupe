

export enum MessageType {
    invocation,
    result,
    error,
    event,
    system
}

export interface Message {
    id: number;
    type: MessageType;
    from: AppearanceLocation;
    to: AppearanceLocation;
    extension: any;
    timestamp: number;
}

export interface InvocationMessage extends Message {
    type: MessageType.invocation;
    reqid: number;
    method: string;
    parameters: any[];
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
    content: string;
    stack: string[];
}


