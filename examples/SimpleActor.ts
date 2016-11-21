import {Actor, SimpleActor} from '../src/actor'
import Promise = require('bluebird')


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

Actor.get<IHelloWorld>('HelloWorld', 'abc')
const hello: IHelloWorld = Actor.get<IHelloWorld>('HelloWorld', 1);
hello.hello().then(console.log)
