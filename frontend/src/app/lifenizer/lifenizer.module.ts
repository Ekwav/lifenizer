import { NgModule } from '@angular/core';
import { CommonModule } from '@angular/common';
import { ImportComponent } from './import/import.component';
import { NgxFileUploadCoreModule } from "@ngx-file-upload/core";
import { Routes, RouterModule } from '@angular/router';
import { NgxDropzoneModule } from 'ngx-dropzone';
import { SearchComponent } from './search/search.component';
import { MatLegacyFormFieldModule as MatFormFieldModule } from '@angular/material/legacy-form-field';
import { NgxUploaderModule } from '@angular-ex/uploader';
import { MatToolbarModule } from '@angular/material/toolbar';
import { MatLegacyInputModule as MatInputModule } from '@angular/material/legacy-input';
import { MatIconModule } from '@angular/material/icon';
import { MatLegacyButtonModule as MatButtonModule } from '@angular/material/legacy-button';
import { MatLegacyAutocompleteModule as MatAutocompleteModule } from '@angular/material/legacy-autocomplete';
import { HttpClientModule } from '@angular/common/http';
import { JwtModule, JWT_OPTIONS } from '@auth0/angular-jwt';
import { AuthService } from './auth.service';
import { ReactiveFormsModule } from '@angular/forms';
import { SecurePipe } from './secure.pipe';

const routes: Routes = [
  {path:"import",component:ImportComponent},
  {path:"search",component:SearchComponent}

];


export function jwtOptionsFactory(authService : AuthService) {
  return {
    tokenGetter: () => {
      return authService.getAsyncToken();
    },
    allowedDomains: ["localhost:5001","localhost:5000","coflnet.com"],
    disallowedRoutes: ["http://localhost:5000/auth/gettoken"],
  }
}

@NgModule({
  declarations: [ImportComponent, SearchComponent, SecurePipe],
  imports: [
    RouterModule.forChild(routes),
    CommonModule,
    NgxDropzoneModule,
    NgxFileUploadCoreModule,
    MatFormFieldModule,
    NgxUploaderModule,
    ReactiveFormsModule,
    MatInputModule,
    MatIconModule,
    MatButtonModule,
    MatAutocompleteModule,
    HttpClientModule,
    JwtModule.forRoot({
      jwtOptionsProvider: {
        provide: JWT_OPTIONS,
        useFactory: jwtOptionsFactory,
        deps: [AuthService]
      }
    }),
  ]
})
export class LifenizerModule { }
