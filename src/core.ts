import shortid = require('shortid');
import {Registry} from './registry';
import {MessageDispatcher} from './dispatcher';
export interface Ref {
    node: string;
    id: string;
}

export type Pid = string | Ref;
type IActorCtor = (new (...args: any[]) => IActor);

export interface IActor {
    pid: string;
    onstart();
    onmessage(message?: any);
    onexit(reason?:any);
    onerror(error:any);

    emit(eventName: string, ...args: any[]);
    // run(...args:any[]):PromiseLike<any>;
}


var dispatcher, eventRouter;
var DefaultActor: IActor;
var registry:{[id:string]:IActor}={};
var nodeId:string = shortid.generate();

/**
 * get the actor according to the name
 */
export function resolve(name: string) {
    return registry[name];
}

/**
 * send a message to the actor with corresponding id
 * the actor can be located remotely
 */
export function send(pid: Pid, args) {
    if (typeof pid === 'string') {
        //local message
        var actor = resolve(pid);
        return actor.onmessage(args);
    }
    return dispatcher.send(pid as Ref, args);
}

/**
 * start an Actor and add it to the registry
 */
export function start<T extends IActor>(ctor: {new(...args:any[]):T}, args?: any[], name?: string): T {
    // register self to the registry
    // dispatcher will find this object from registry
    // Actor.register(this);
    if(!name){
        name = shortid.generate();
    }
    
    var actor = new ctor(...args);
    actor.pid = name;
    registry[name] = actor;
    return actor;
}

export function bootstrap(cb?:Function){
     dispatcher = new MessageDispatcher(Node.current().id);
     if(cb){cb();}
}

export function exit() {
    
}
/**
 * stop an Actor and remove it from the registry
 */
export function stop(actor: IActor, reason?:any) {
    delete registry[actor.pid];
    actor.onexit(reason);
}