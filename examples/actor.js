// Define a Actor Role (class)
// Or Role.define

class RemoteReference {
    constructor(){

    }

    invoke(name, args){
        this.invoker.invoke(this.address, name, args)
    }
}

const Actor = {
    roles: null,
    references: null
}
const Role = {
    all: {},
    get: function (name) {
        return this.all[name]
    },
    define: function (name, trait) {
        var role = function () { }
        role.prototype = trait;
        for (var methodName in trait) {
            var s = methodName.charAt(0), method = trait[methodName]
            if (trait.hasOwnProperty(methodName) && typeof method === 'function' && s !== '_' && s !== '$') {
// define role method
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