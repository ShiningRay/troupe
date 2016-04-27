import {Actor, Ref} from './index';
import * as Redis from 'ioredis';
import child_process = require('child_process')
import Proimse = require('bluebird');


class User extends Actor {
    constructor(private name: string) {
        super();
    }

    hello(content) {
        console.log(this.pid, "#", this.name, ":", content);
        // return new Promise((resolve, reject) => {
        //     setTimeout(() => resolve(`${this.name}######replied`), 2000);
        // });
        return 1984;
    }
}
var ischild: boolean = false;
var ref: Ref;
console.log(process.argv)
Actor.init(function () {
    if (process.argv.length > 2) {
        console.log('child', Actor.dispatcher.processId);
        var r = process.argv[2].split('#');
        ref = { node: r[0], id: r[1] };
        console.log(ref);
        Actor.invoke(ref, "hello", ["world"]).then((data) => 
            console.log('child received result from parent:', data)
        ).catch(
            (err) => console.log('child received error:', err)
        );
            
    } else {
        console.log('parent', Actor.dispatcher.processId);
        var user = Actor.start(User, ["father"]);
        var child = child_process.fork(__filename, [`${Actor.dispatcher.processId}#${user.pid}`]);
    }
})