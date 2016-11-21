import {Actor} from './actor'

class Role {
    all:any= {}
    referenceClasses:any= {}

    get (name) {
        return this.all[name]
    }

    static define (name, trait) {
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
    }
    generateReference(methodNames){

    }
}