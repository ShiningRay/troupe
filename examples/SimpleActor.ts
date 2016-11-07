import * as Promise from 'bluebird';
/**
 * T stands for the interface actor type shared with reference
 */
abstract class ActorReference {

}

class Actor {
    static roles: { [name: string]: Function }
    static references;
    static get<T>(type: string, id: any): T {
        let role = this.references[type]
        return
    }
}

type Constructor<T> = new (...args: any[]) => T;
// Actor.Base = Base;


abstract class AbstractActor<State> {

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
class Stage {

}
/**
 * address
 */
class AppearanceLocation {
    stage: Stage;
}

interface IActorDirectory {
    register();
    unregister();
    lookup();
}

class ActorDirectory {
    private _map:{[id:string]:SimpleActor}
}

/**
 * Active actor in system
 * contains some runtime information
 */
class Appearance {
    private mailbox:any[];
    private processing:boolean = false;
    private actor: Actor;
    private reference: ActorReference;
    private execute:Function;

    onmessage(message:any){
        if(this.processing)
            this.mailbox.push(message);
        else
            this.execute(message);
    }

    run(message:any):PromiseLike<any>{
        return
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


interface IHelloWorld {
    hello(): PromiseLike<string>;
    getCounter(): PromiseLike<number>;
}

class HelloWorld extends SimpleActor implements IHelloWorld {
    private _counter:number=0;
    constructor(private _id: string) {
        super(_id)
    }

    hello(): PromiseLike<string> {
        this._counter ++;
        return Promise.resolve('world')
    }

    getCounter():PromiseLike<number>{
        return Promise.resolve(this._counter);
    }
}
//if don't specify class id, then use class's name
// generated by system
class HelloWorldReference extends ActorReference implements IHelloWorld {

    hello(): PromiseLike<string> {
        return Promise.resolve('world')
    }

    getCounter():PromiseLike<number>{
        return Promise.resolve
    }
}


const hello: IHelloWorld = Actor.get<IHelloWorld>('HelloWorld', 1);
hello.hello().then(console.log)