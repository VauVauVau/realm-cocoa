////////////////////////////////////////////////////////////////////////////
//
// Copyright 2015 Realm Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
////////////////////////////////////////////////////////////////////////////

#import "RLMNotification.hpp"

#import "RLMObjectSchema_Private.hpp"
#import "RLMProperty_Private.h"
#import "RLMRealm_Private.hpp"
#import "RLMSchema.h"

RLMObservationInfo::RLMObservationInfo(RLMObjectSchema *objectSchema, std::size_t row, id object)
: object(object)
, objectSchema(objectSchema)
{
    setRow(*objectSchema.table, row);
}

RLMObservationInfo::RLMObservationInfo(id object)
: object(object)
{
}

RLMObservationInfo::~RLMObservationInfo() {
    if (prev) {
        prev->next = next;
        if (next)
            next->prev = prev;
    }
    else if (objectSchema) {
        for (auto it = objectSchema->_observedObjects.begin(), end = objectSchema->_observedObjects.end(); it != end; ++it) {
            if (*it == this) {
                if (next)
                    *it = next;
                else {
                    iter_swap(it, std::prev(end));
                    objectSchema->_observedObjects.pop_back();
                }
                return;
            }
        }
    }
}

void RLMObservationInfo::setRow(realm::Table &table, size_t newRow) {
    REALM_ASSERT(!row);
    row = table[newRow];
    for (auto info : objectSchema->_observedObjects) {
        if (info->row && info->row.get_index() == row.get_index()) {
            prev = info;
            next = info->next;
            info->next = this;
            return;
        }
    }
    objectSchema->_observedObjects.push_back(this);
}

void RLMObservationInfo::recordObserver(realm::Row& objectRow,
                                        __unsafe_unretained RLMObjectSchema *const objectSchema,
                                        __unsafe_unretained id const observer,
                                        __unsafe_unretained NSString *const keyPath,
                                        NSKeyValueObservingOptions options,
                                        void *context) {
    // add ourselves to the list of observed objects if this is the first time
    // an observer is being added to a persisted object
    if (objectRow && !row) {
        this->objectSchema = objectSchema;
        setRow(*objectRow.get_table(), objectRow.get_index());
    }

    // record the observation if the object is standalone
    if (!row) {
        standaloneObservers.push_back({observer, options, context, keyPath});
    }
}

void RLMObservationInfo::removeObservers() {
    currentlyUnregisteringObservers = true;
    for (auto const& info : standaloneObservers) {
        [object removeObserver:info.observer forKeyPath:info.key context:info.context];
    }

}

void RLMObservationInfo::restoreObservers() {
    for (auto const& info : standaloneObservers) {
        [object addObserver:info.observer
                 forKeyPath:info.key
                    options:info.options & ~NSKeyValueObservingOptionInitial
                    context:info.context];
    }
    standaloneObservers.clear();
}

void RLMForEachObserver(RLMObjectBase *obj, void (^block)(RLMObjectBase*)) {
    RLMObservationInfo *info = obj->_observationInfo.get();
    if (!info) {
        for (RLMObservationInfo *o : obj->_objectSchema->_observedObjects) {
            if (obj->_row.get_index() == o->row.get_index()) {
                info = o;
                break;
            }
        }
    }
    for_each(info, block);
}

void RLMTrackDeletions(__unsafe_unretained RLMRealm *const realm, dispatch_block_t block) {
    struct change {
        RLMObservationInfo *observable;
        __unsafe_unretained NSString *property;
    };
    std::vector<change> changes;
    struct arrayChange {
        RLMObservationInfo *observable;
        __unsafe_unretained NSString *property;
        NSMutableIndexSet *indexes;
    };
    std::vector<arrayChange> arrayChanges;

    realm.group->set_cascade_notification_handler([&](realm::Group::CascadeNotification const& cs) {
        for (auto const& row : cs.rows) {
            for (RLMObjectSchema *objectSchema in realm.schema.objectSchema) {
                if (objectSchema.table->get_index_in_group() != row.table_ndx)
                    continue;
                for (auto observer : objectSchema->_observedObjects) {
                    if (observer->row && observer->row.get_index() == row.row_ndx) {
                        changes.push_back({observer, @"invalidated"});
                        for (RLMProperty *prop in objectSchema.properties)
                            changes.push_back({observer, prop.name});
                        break;
                    }
                }
                break;
            }
        }
        for (auto const& link : cs.links) {
            for (RLMObjectSchema *objectSchema in realm.schema.objectSchema) {
                if (objectSchema.table->get_index_in_group() != link.origin_table->get_index_in_group())
                    continue;
                for (auto observer : objectSchema->_observedObjects) {
                    if (observer->row.get_index() != link.origin_row_ndx)
                        continue;
                    RLMProperty *prop = objectSchema.properties[link.origin_col_ndx];
                    NSString *name = prop.name;
                    if (prop.type != RLMPropertyTypeArray)
                        changes.push_back({observer, name});
                    else {
                        auto linkview = observer->row.get_linklist(prop.column);
                        arrayChange *c = nullptr;
                        for (auto& ac : arrayChanges) {
                            if (ac.observable == observer && ac.property == name) {
                                c = &ac;
                                break;
                            }
                        }
                        if (!c) {
                            arrayChanges.push_back({observer, name, [NSMutableIndexSet new]});
                            c = &arrayChanges.back();
                        }

                        size_t start = 0, index;
                        while ((index = linkview->find(link.old_target_row_ndx, start)) != realm::not_found) {
                            [c->indexes addIndex:index];
                            start = index + 1;
                        }
                    }
                    break;
               }
                break;
            }
        }

        for (auto const& change : changes)
            for_each(change.observable, [&](auto o) { [o willChangeValueForKey:change.property]; });
        for (auto const& change : arrayChanges)
            for_each(change.observable, [&](auto o) { [o willChange:NSKeyValueChangeRemoval valuesAtIndexes:change.indexes forKey:change.property]; });
    });

    block();

    for (auto const& change : changes) {
        change.observable->setReturnNil(true);
        for_each(change.observable, [&](auto o) { [o didChangeValueForKey:change.property]; });
    }
    for (auto const& change : arrayChanges) {
        change.observable->setReturnNil(true);
        for_each(change.observable, [&](auto o) { [o didChange:NSKeyValueChangeRemoval valuesAtIndexes:change.indexes forKey:change.property]; });
    }

    realm.group->set_cascade_notification_handler(nullptr);
}

template<typename Container, typename Pred>
static void erase_if(Container&& c, Pred&& p) {
    auto it = find_if(c.begin(), c.end(), p);
    if (it != c.end()) {
        iter_swap(it, prev(c.end()));
        c.pop_back();
    }
}

void RLMOverrideStandaloneMethods(Class cls) {
    struct methodInfo {
        SEL sel;
        IMP imp;
        const char *type;
    };

    auto make = [](SEL sel, auto&& func) {
        Method m = class_getInstanceMethod(NSObject.class, sel);
        IMP superImp = method_getImplementation(m);
        const char *type = method_getTypeEncoding(m);
        IMP imp = imp_implementationWithBlock(func(sel, superImp));
        return methodInfo{sel, imp, type};
    };

    static const methodInfo methods[] = {
        make(@selector(removeObserver:forKeyPath:), [](SEL sel, IMP superImp) {
            auto superFn = (void (*)(id, SEL, id, NSString *))superImp;
            return ^(RLMObjectBase *self, id observer, NSString *keyPath) {
                if (RLMObservationInfo *info = self->_observationInfo.get()) {
                    if (!info->currentlyUnregisteringObservers) {
                    erase_if(info->standaloneObservers, [&](auto const& info) {
                        return info.observer == observer && [info.key isEqualToString:keyPath];
                    });
                    }
                }
                superFn(self, sel, observer, keyPath);
            };
        }),

        make(@selector(removeObserver:forKeyPath:context:), [](SEL sel, IMP superImp) {
            auto superFn = (void (*)(id, SEL, id, NSString *, void *))superImp;
            return ^(RLMObjectBase *self, id observer, NSString *keyPath, void *context) {
                if (RLMObservationInfo *info = self->_observationInfo.get()) {
                    if (!info->currentlyUnregisteringObservers) {
                    erase_if(info->standaloneObservers, [&](auto const& info) {
                        return info.observer == observer
                            && info.context == context
                            && [info.key isEqualToString:keyPath];
                    });
                    }
                }
                superFn(self, sel, observer, keyPath, context);
            };
        })
    };

    for (auto const& m : methods)
        class_addMethod(cls, m.sel, m.imp, m.type);
}
