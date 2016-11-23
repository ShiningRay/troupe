import {AbstractActor} from './actor'
import _ = require('lodash')
import eval2 = require('eval2')

const ActorTemplate = `
(function(inherits, AbstractActor){
    var actorClass = function(){
        AbstractActor.call(this);
    }
    inherits(actorClass, AbstractActor);
    <% _.each(trait, (method, name) => {%>
    actorClass.prototype.<%= name %> = <%= method %>
    <% } %>    
    return actorClass;
})
`

const ReferenceTemplate = `
(function(inherits, Reference){
    var referenceClass = function(){

    }
    inherits(referenceClass, Reference);
    <% _.each(trait, (method, name) => {%>
    referenceClass.prototype.<%= name %> = <%= method %>
    <% } %>
    return referenceClass;
})
`

const FactoryTemplate = `
`


class Role {
    actorClasses:{[key:string]: Function} = {}
    referenceClasses:{[key:string]: Function}= {}
    factoryClasses:{[key:string]: Function} = {}

    getActor(name) {
        return this.actorClasses[name];
    }

    getReference(name){
        return this.referenceClasses[name];
    }

    getFactory(name){
        return this.factoryClasses[name]
    }

    static define<Trait=any>(name, trait:Trait) {
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
        this.actorClasses[name] = role; 
        return role;
    }

    static register<Trait=any>(name, actorClass:Actor){

    }

    static extends<Trait>(name, parent, trait:Trait){

    }
    static generateReference(methodNames){

    }
}