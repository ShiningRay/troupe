import shortid = require('shortid');
import {Registry} from './registry';


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

export interface IActorProxy {
  on(eventName: string);
}


var dispatcher, eventRouter;
var registry:{[id:string]:IActor}={};
export var nodeId:string = shortid.generate();

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

// stop all actors and finally exit current process
// TODO
export function exit() {
    
}
/**
 * stop an Actor and remove it from the registry
 */
export function stop(actor: IActor, reason?:any) {
    delete registry[actor.pid];
    actor.onexit(reason);
}

var callbacks:Function[] = [];

export function onBootstrap(cb:Function){
    callbacks.push(cb);
}

interface ClusterConfig{
    
}
import {EventRouter} from './events'
export function bootstrap(config?:ClusterConfig, cb?:Function){
     dispatcher = new MessageDispatcher(nodeId);
     eventRouter = new EventRouter();
     callbacks.forEach((fn) => fn());
     if(cb){cb();}
     
}

export function toRef(actor:any):Ref{
    if(typeof actor == 'string'){
        return {node: nodeId, id: actor}
    } else if('pid' in actor){
        if(typeof actor.pid == 'string'){
            return {node: nodeId, id: actor.pid}
        } else {
            return actor.pid;
        }
    } else if(('node' in actor) && ('id' in actor)){
        return actor;
    }
}



// Theater: Machine ?
// Director: Dispatcher ?
// Scenario: Runtime
// Stage: Process

// Dialogue
interface Dialogue {
    method: string;
    args: any[];
}
// Drama

// Troupe: Whole system
interface Troupe {

}


interface ActorDirectory {
    find
}