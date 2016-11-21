// Define a Actor Role (class)
// Or Role.define
const inherits = require('utils').inherits;
class Reference {
    
}
class RemoteReference {
    constructor(){
        this.invoker = Scenario.current.invoker;
    }

    invoke(name, args){
        return this.invoker.invoke(this.address, name, args)
    }
}

class Invoker {

}

function Scenario(){
    this.invoker = new Invoker();
}

Scenario.current = new Scenario();

const Actor = {
    roles: null,
    references: null
}
const Role = {
    all: {},
    referenceClasses: {},
    get: function (name) {
        return this.all[name]
    },
    define: function (name, trait) {
        // var role = function () { }
        // role.prototype = trait;
        var referenceClass = function(){
            RemoteReference.call(this)
        }

        inherits(referenceClass, RemoteReference)

        for (var methodName in trait) {
            var s = methodName.charAt(0), method = trait[methodName]
            if (trait.hasOwnProperty(methodName) && typeof method === 'function' && s !== '_' && s !== '$') {
// define role method
                referenceClass.prototype[methodName] = new Function("return this.invoke('"+methodName+"', arguments)")
            }
        }
        this.all[name] = role; 
        return role;
    },
    generateReference: function(methodNames){

    }
}
Actor.roles = Role.all;
const HelloWorld = Role.define('HelloWorld', {
    hello: function () {
        return Promise.resolve('world')
    }
});

// HelloWorld.name
// Actor.roles.HelloWorld
// Actor.references.HelloWorld -> reference class of HelloWorld
var actor = Actor.find('HelloWorld', 1)
actor.hello().then(console.log)