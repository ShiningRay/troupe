import {EventEmitter} from 'events'
import * as Promise from 'bluebird';
import { Scenario } from './scenario'
/**
 * T stands for the interface actor type shared with reference
 */
export abstract class RemoteReference<T> {
    interfaceName: string;
    interfaceClass: new (...args:any[]) => T;    
    constructor(){
        
    }

    invoke(name, args){
        return Scenario.current.invoke(this.address, name, args)
    }

    static generateSubclass(){

    }
}

/**
 * 
 */
export class Actor {
    static roles: { [name: string]: Function }
    static references;
    static get<Trait>(roleName: string, id: any): Trait {
        let role = this.references[type]
        return
    }
}



type Constructor<T> = new (...args: any[]) => T;
// Actor.Base = Base;

export abstract class AbstractActor<State> {

    static readonly role;

    public readonly id: string;
    protected appearance: Appearance;
    protected state: State;

    constructor(id: string) {
        this.id = id;
    }

    set(key: string, value: any): this {
        this.state[key] = value;
        return this;
    }

    setState(obj: any): this {
        return this;
    }

    replaceState(state: State): this {
        this.state = state;
        return this;
    }
}

abstract class SimpleActor extends AbstractActor<any> {
    constructor(id: string) {
        super(id);
    }
}

type Trait = { [name: string]: Function }

interface ActorConstructor {

}

interface RoleConstructor {
    /**
     * decorator
     */
    (name?: string): any;
    define?(name: string, trait: Trait): ActorConstructor;
    all?: Trait;
}

const Role: RoleConstructor = function (name?: string) {
    return function (ctor) {
        ctor['roleName'] = name;
    }
}

Role.define = function (): ActorConstructor {
    var role
    return role
}


//if don't specify class id, then use class's name
// generated by system
class HelloWorldReference extends ActorReference implements IHelloWorld {

    hello(): PromiseLike<string> {
        return Promise.resolve('world')
    }

    getCounter():PromiseLike<number>{
        return Promise.resolve()
    }
}



interface AppearanceLocation {
    stage: Stage;
}

interface ActorDirectory {
    register( address: AppearanceLocation,  singleActivation: boolean,  hopCount:number);
    unregister( address: AppearanceLocation, cause: string, hopCount: number)
    lookup()
}

/**
 * LRU-style, will deactivate inactive actors perodicly 
 */
abstract class LocalActorDirectory implements ActorDirectory{
    register()
}

abstract class RemoteActorDirectory {

}

/**
 * interner will use weak reference to cache some actor references
 * acts as cache
 */
interface Interner {

}

class JSONMessageEncoder extends Transform {
    constructor(){
        super({ objectMode: true });
    }
    transform(chunk, encoding, cb){

    }
} 

/**
 * router to send message to correct actor; 
 */
interface MessageRouter {
    sendTo(actor:RemoteReference, messageType:MessageType):this;
    send(message:Message):this;
}

/**
 * receive incoming messages and findout correct actor to respond it
 */
interface MessageDispatcher {
    on(type:'message', callback: (message:Message) => any):this;
}
